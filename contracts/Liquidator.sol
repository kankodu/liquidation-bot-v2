// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISwapper} from "./ISwapper.sol";
import {SwapVerifier} from "./SwapVerifier.sol";
import {IEVC} from "./IEVC.sol";

import {IERC4626, IERC20} from "./IEVault.sol";
import {IEVault, IRiskManager, IBorrowing, ILiquidation} from "./IEVault.sol";

import {IPyth} from "./IPyth.sol";

interface IERC721WrapperBase {
    function getEnabledTokenIds(address owner) external view returns (uint256[] memory);
    function balanceOf(address owner, uint256 tokenId) external view returns (uint256);
    function unwrap(address from, uint256 tokenId, address to, uint256 amount, bytes calldata extraData) external;
}

contract Liquidator {
    address public immutable owner;
    address public immutable swapperAddress;
    address public immutable swapVerifierAddress;
    address public immutable evcAddress;

    address public immutable PYTH;

    ISwapper swapper;
    IEVC evc;

    error Unauthorized();
    error LessThanExpectedCollateralReceived();

    constructor(address _owner, address _swapperAddress, address _swapVerifierAddress, address _evcAddress, address _pythAddress) {
        owner = _owner;
        swapperAddress = _swapperAddress;
        swapVerifierAddress = _swapVerifierAddress;
        evcAddress = _evcAddress;
        PYTH = _pythAddress;

        swapper = ISwapper(_swapperAddress);
        evc = IEVC(_evcAddress);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized");
        _;
    }

    struct LiquidationParams {
        address violatorAddress;
        address vault;
        address borrowedAsset;
        address collateralVault;
        address collateralAsset;
        uint256 repayAmount;
        uint256 seizedCollateralAmount;
        address receiver;
        address additionalToken;
    }

    event Liquidation(
        address indexed violatorAddress,
        address indexed vault,
        address repaidBorrowAsset,
        address seizedCollateralAsset,
        uint256 amountRepaid,
        uint256 amountCollaterallSeized
    );

    /// @notice Redeem collateral from an EVault or unwrap from an ERC721 wrapper
    /// @dev Tries IERC4626.asset() first. If it succeeds, the collateral is an EVault and we redeem.
    ///      If it reverts, we treat it as a wrapper and unwrap all enabled token IDs.
    function redeemOrUnwrap(address collateralVault, uint256 maxYield, address recipient) external {
        require(msg.sender == address(this), "Unauthorized");

        // Try to call asset() to determine if this is an EVault
        (bool isEVault, ) = collateralVault.staticcall(abi.encodeCall(IERC4626.asset, ()));

        if (isEVault) {
            // Standard EVault: redeem shares for underlying asset to recipient
            IERC4626(collateralVault).redeem(maxYield, recipient, address(this));
        } else {
            // ERC721 Wrapper: unwrap all enabled token IDs to recipient
            IERC721WrapperBase wrapper = IERC721WrapperBase(collateralVault);
            uint256[] memory tokenIds = wrapper.getEnabledTokenIds(address(this));
            for (uint256 i = 0; i < tokenIds.length; i++) {
                uint256 balance = wrapper.balanceOf(address(this), tokenIds[i]);
                if (balance > 0) {
                    wrapper.unwrap(address(this), tokenIds[i], recipient, balance, "");
                }
            }
        }
    }

    function liquidateSingleCollateral(LiquidationParams calldata params, bytes[] calldata swapperData) external returns (bool success) {
        // Build multicall: swap data items + repay + sweep borrowed asset + optional sweeps
        uint256 extraSweeps = 0;
        if (params.collateralAsset != address(0)) extraSweeps++;
        if (params.additionalToken != address(0)) extraSweeps++;

        bytes[] memory multicallItems = new bytes[](swapperData.length + 2 + extraSweeps);

        for (uint256 i = 0; i < swapperData.length; i++){
            multicallItems[i] = swapperData[i];
        }

        // Use swapper contract to repay borrowed asset
        multicallItems[swapperData.length] =
            abi.encodeCall(ISwapper.repay, (params.borrowedAsset, params.vault, type(uint256).max, address(this)));

        // Sweep borrowed asset dust to receiver
        multicallItems[swapperData.length + 1] = abi.encodeCall(ISwapper.sweep, (params.borrowedAsset, 0, params.receiver));

        // Sweep collateral asset if present (wrapper: one of the two tokens may match borrowed)
        uint256 sweepIdx = swapperData.length + 2;
        if (params.collateralAsset != address(0)) {
            multicallItems[sweepIdx] = abi.encodeCall(ISwapper.sweep, (params.collateralAsset, 0, params.receiver));
            sweepIdx++;
        }
        // Sweep additional token if present (wrapper: second unwrapped token)
        if (params.additionalToken != address(0)) {
            multicallItems[sweepIdx] = abi.encodeCall(ISwapper.sweep, (params.additionalToken, 0, params.receiver));
        }

        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](7);

        // Step 1: enable controller
        batchItems[0] = IEVC.BatchItem({
            onBehalfOfAccount: address(0),
            targetContract: address(evc),
            value: 0,
            data: abi.encodeCall(IEVC.enableController, (address(this), params.vault))
        });

        // Step 2: enable collateral
        batchItems[1] = IEVC.BatchItem({
            onBehalfOfAccount: address(0),
            targetContract: address(evc),
            value: 0,
            data: abi.encodeCall(IEVC.enableCollateral, (address(this), params.collateralVault))
        });

        (uint256 maxRepay, uint256 maxYield) = ILiquidation(params.vault).checkLiquidation(address(this), params.violatorAddress, params.collateralVault);

        // Step 3: Liquidate account in violation
        batchItems[2] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: params.vault,
            value: 0,
            data: abi.encodeCall(
                ILiquidation.liquidate,
                (params.violatorAddress, params.collateralVault, maxRepay, 0)
            )
        });

        // Step 4: Redeem collateral (EVault) or unwrap (ERC721 wrapper) to swapper
        batchItems[3] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: address(this),
            value: 0,
            data: abi.encodeCall(this.redeemOrUnwrap, (params.collateralVault, maxYield, swapperAddress))
        });

        // Step 5: Swap collateral for borrowed asset, repay, and sweep
        batchItems[4] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: swapperAddress,
            value: 0,
            data: abi.encodeCall(ISwapper.multicall, multicallItems)
        });

        batchItems[5] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: params.vault,
            value: 0,
            data: abi.encodeCall(IRiskManager.disableController, ())
        });

        batchItems[6] = IEVC.BatchItem({
            onBehalfOfAccount: address(0),
            targetContract: address(evc),
            value: 0,
            data: abi.encodeCall(IEVC.disableCollateral, (address(this), params.collateralVault))
        });


        // Submit batch to EVC
        evc.batch(batchItems);

        emit Liquidation(
            params.violatorAddress,
            params.vault,
            params.borrowedAsset,
            params.collateralAsset,
            params.repayAmount,
            params.seizedCollateralAmount
        );

        if (IERC20(params.collateralVault).balanceOf(address(this)) > 0) {
            IERC20(params.collateralVault).transfer(params.receiver, IERC20(params.collateralVault).balanceOf(address(this)));
        }

        return true;
    }

    function liquidateSingleCollateralWithPythOracle(LiquidationParams calldata params, bytes[] calldata swapperData, bytes[] calldata pythUpdateData) external payable returns (bool success) {
        // Build multicall: swap data items + repay + sweep borrowed asset + optional sweeps
        uint256 extraSweeps = 0;
        if (params.collateralAsset != address(0)) extraSweeps++;
        if (params.additionalToken != address(0)) extraSweeps++;

        bytes[] memory multicallItems = new bytes[](swapperData.length + 2 + extraSweeps);

        for (uint256 i = 0; i < swapperData.length; i++){
            multicallItems[i] = swapperData[i];
        }

        // Use swapper contract to repay borrowed asset
        multicallItems[swapperData.length] =
            abi.encodeCall(ISwapper.repay, (params.borrowedAsset, params.vault, type(uint256).max, address(this)));

        // Sweep borrowed asset dust to receiver
        multicallItems[swapperData.length + 1] = abi.encodeCall(ISwapper.sweep, (params.borrowedAsset, 0, params.receiver));

        // Sweep collateral asset if present (wrapper: one of the two tokens may match borrowed)
        uint256 sweepIdx = swapperData.length + 2;
        if (params.collateralAsset != address(0)) {
            multicallItems[sweepIdx] = abi.encodeCall(ISwapper.sweep, (params.collateralAsset, 0, params.receiver));
            sweepIdx++;
        }
        // Sweep additional token if present (wrapper: second unwrapped token)
        if (params.additionalToken != address(0)) {
            multicallItems[sweepIdx] = abi.encodeCall(ISwapper.sweep, (params.additionalToken, 0, params.receiver));
        }

        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](7);

        // Update Pyth oracles
        IPyth(PYTH).updatePriceFeeds{value: msg.value}(pythUpdateData);

        // Step 1: enable controller
        batchItems[0] = IEVC.BatchItem({
            onBehalfOfAccount: address(0),
            targetContract: address(evc),
            value: 0,
            data: abi.encodeCall(IEVC.enableController, (address(this), params.vault))
        });

        (uint256 maxRepay, uint256 maxYield) = ILiquidation(params.vault).checkLiquidation(address(this), params.violatorAddress, params.collateralVault);

        // Step 2: enable collateral
        batchItems[1] = IEVC.BatchItem({
            onBehalfOfAccount: address(0),
            targetContract: address(evc),
            value: 0,
            data: abi.encodeCall(IEVC.enableCollateral, (address(this), params.collateralVault))
        });

        // Step 3: Liquidate account in violation
        batchItems[2] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: params.vault,
            value: 0,
            data: abi.encodeCall(
                ILiquidation.liquidate,
                (params.violatorAddress, params.collateralVault, maxRepay, 0)
            )
        });

        // Step 4: Redeem collateral (EVault) or unwrap (ERC721 wrapper) to swapper
        batchItems[3] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: address(this),
            value: 0,
            data: abi.encodeCall(this.redeemOrUnwrap, (params.collateralVault, maxYield, swapperAddress))
        });

        // Step 5: Swap collateral for borrowed asset, repay, and sweep
        batchItems[4] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: swapperAddress,
            value: 0,
            data: abi.encodeCall(ISwapper.multicall, multicallItems)
        });

        batchItems[5] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: params.vault,
            value: 0,
            data: abi.encodeCall(IRiskManager.disableController, ())
        });

        batchItems[6] = IEVC.BatchItem({
            onBehalfOfAccount: address(0),
            targetContract: address(evc),
            value: 0,
            data: abi.encodeCall(IEVC.disableCollateral, (address(this), params.collateralVault))
        });


        // Submit batch to EVC
        evc.batch(batchItems);

        emit Liquidation(
            params.violatorAddress,
            params.vault,
            params.borrowedAsset,
            params.collateralAsset,
            params.repayAmount,
            params.seizedCollateralAmount
        );

        if (IERC20(params.collateralVault).balanceOf(address(this)) > 0) {
            IERC20(params.collateralVault).transfer(params.receiver, IERC20(params.collateralVault).balanceOf(address(this)));
        }

        return true;
    }


    // 2nd liquidation option: seize liquidated position without swapping/repaying, can only be done with existing collateral position
    // TODO: implement this as an operator so debt can be seized directly by whitelisted liquidators
    function liquidateFromExistingCollateralPosition(LiquidationParams calldata params)
        external
        returns (bool success)
    {
        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](3);

        batchItems[0] = IEVC.BatchItem({
            onBehalfOfAccount: address(0),
            targetContract: evcAddress,
            value: 0,
            data: abi.encodeCall(IEVC.enableController, (address(this), params.vault))
        });

        batchItems[1] = IEVC.BatchItem({
            onBehalfOfAccount: address(0),
            targetContract: evcAddress,
            value: 0,
            data: abi.encodeCall(IEVC.enableCollateral, (address(this), params.collateralVault))
        });

        batchItems[2] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: params.vault,
            value: 0,
            data: abi.encodeCall(
                ILiquidation.liquidate,
                (params.violatorAddress, params.collateralVault, params.repayAmount, params.seizedCollateralAmount)
            )
        });

        // batchItems[3] = IEVC.BatchItem({
        //     onBehalfOfAccount: address(this),
        //     targetContract: params.vault,
        //     value: 0,
        //     data: abi.encodeCall(
        //         IBorrowing.pullDebt(amount, from)
        //         (params.expectedRemainingCollateral, params.receiver, address(this))
        //     )
        // });

        evc.batch(batchItems);

        emit Liquidation(
            params.violatorAddress,
            params.vault,
            params.borrowedAsset,
            params.collateralAsset,
            params.repayAmount,
            params.seizedCollateralAmount
        );

        return true;
    }

    function simulatePythUpdateAndGetAccountStatus(bytes[] calldata pythUpdateData, uint256 pythUpdateFee, address vaultAddress, address accountAddress) external payable returns (uint256 collateralValue, uint256 liabilityValue) {
        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](2);

        batchItems[0] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: PYTH,
            value: pythUpdateFee,
            data: abi.encodeCall(IPyth.updatePriceFeeds, pythUpdateData)
        });

        batchItems[1] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: vaultAddress,
            value: 0,
            data: abi.encodeCall(IRiskManager.accountLiquidity, (accountAddress, true))
        });

        (IEVC.BatchItemResult[] memory batchItemsResult,,) = evc.batchSimulation{value: pythUpdateFee}(batchItems);

        (collateralValue, liabilityValue) = abi.decode(batchItemsResult[1].result, (uint256, uint256));

        return (collateralValue, liabilityValue);
    }

    function simulatePythUpdateAndCheckLiquidation(bytes[] calldata pythUpdateData, uint256 pythUpdateFee, address vaultAddress, address liquidatorAddress, address borrowerAddress, address collateralAddress) external payable returns (uint256 maxRepay, uint256 seizedCollateral) {
        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](2);

        batchItems[0] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: PYTH,
            value: pythUpdateFee,
            data: abi.encodeCall(IPyth.updatePriceFeeds, pythUpdateData)
        });

        batchItems[1] = IEVC.BatchItem({
            onBehalfOfAccount: address(this),
            targetContract: vaultAddress,
            value: 0,
            data: abi.encodeCall(ILiquidation.checkLiquidation, (liquidatorAddress, borrowerAddress, collateralAddress))
        });

        (IEVC.BatchItemResult[] memory batchItemsResult,,) = evc.batchSimulation{value: pythUpdateFee}(batchItems);

        (maxRepay, seizedCollateral) = abi.decode(batchItemsResult[1].result, (uint256, uint256));

        return (maxRepay, seizedCollateral);
    }
}
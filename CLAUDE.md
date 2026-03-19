# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

A multi-chain liquidation bot for the Euler Protocol. It monitors EVC (Ethereum Vault Connector) events to track account positions, calculates health scores, simulates liquidations, gets swap quotes via 1Inch API, checks profitability against gas costs, and executes liquidations via `Liquidator.sol`.

## Commands

### Python Setup
```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
mkdir logs state
```

### Run Locally
```bash
flask run --port 8080
```

### Docker
```bash
docker compose build --progress=plain && docker compose up
```

### Solidity Contracts
```bash
# Install Foundry
foundryup

# Build contracts
forge install && forge build

# Deploy liquidator contract
forge script contracts/DeployLiquidator.sol --rpc-url $RPC_URL --broadcast --ffi -vvv --slow --evm-version shanghai

# Run liquidation setup test (creates positions on a fork)
forge script test/LiquidationSetupWithVaultCreated.sol --rpc-url $RPC_URL --broadcast --ffi -vvv --slow --evm-version shanghai

# Run Foundry tests
forge test
```

### Linting
```bash
pylint app/
```

## Architecture

### Core Flow
1. `EVCListener` scans `AccountStatusCheck` events from the EVC contract to discover accounts
2. `AccountMonitor` maintains a priority queue of accounts, scheduling updates based on health score and position size
3. For unhealthy accounts (health < 1.0), `Liquidator` simulates liquidation across each collateral asset
4. `Quoter` uses the 1Inch API with binary search to find the exact swap amount needed to repay debt
5. Profitability check: simulate tx gas cost vs. expected profit in ETH terms
6. Execution: `Liquidator.sol` performs a 7-step EVC batch (enable collateral, enable controller, liquidate, swap via ISwapper, repay, disable controller, sweep profit)
7. Excess collateral goes to `profit_receiver` as eTokens

### Key Classes (`app/liquidation/liquidation_bot.py`)
- **`Vault`** — Wraps EVault contract; calls `accountLiquidity()`, `checkLiquidation()`, and other vault methods
- **`Account`** — Tracks health score, position size, and update scheduling for a single account
- **`AccountMonitor`** — Main orchestrator; priority queue loop that calls vault liquidity checks and triggers liquidations
- **`EVCListener`** — Subscribes to EVC `AccountStatusCheck` logs to add/refresh accounts
- **`SmartUpdateListener`** — Allows manual account update triggers
- **`Liquidator`** — Static methods: `simulate_liquidation()`, `execute_liquidation()`, `binary_search_swap_amount()`
- **`PullOracleHandler`** — Fetches and batches Pyth oracle price updates for accurate on-chain pricing
- **`Quoter`** — Wraps 1Inch API calls with retry logic and slippage handling

### Supporting Modules
- **`bot_manager.py`** — `ChainManager` instantiates one `AccountMonitor` + `EVCListener` per configured chain
- **`config_loader.py`** — Loads `config.yaml` and `.env`; provides `ChainConfig` with per-chain contract addresses and Web3 instance
- **`utils.py`** — Logging setup, contract creation helpers, Slack notifications, API request wrapper
- **`routes.py`** — Flask endpoints: `GET /allPositions` returns all tracked accounts across chains
- **`application.py`** — Flask app factory entry point

### Configuration
**`config.yaml`** — Main config with:
- Health score thresholds (`HS_LIQUIDATION`, `HS_HIGH_RISK`, `HS_SAFE`)
- Update interval matrix (position size bucket × health bucket → seconds between checks)
- Per-chain contract addresses (EVC, LIQUIDATOR_CONTRACT, SWAPPER, SWAP_VERIFIER, WETH, PYTH)
- API parameters (retries, slippage, swap delays)
- Profit receiver address

**`.env`** (from `.env.example`):
```
LIQUIDATOR_EOA=<public key>
LIQUIDATOR_PRIVATE_KEY=<private key>
MAINNET_RPC_URL=...
BASE_RPC_URL=...
SWAP_API_URL=<1inch endpoint>
SLACK_WEBHOOK_URL=<optional>
```

### Multi-Chain Support
Chains are identified by chain ID in `config.yaml`. Currently configured: Ethereum (1), Base (8453), Swell (1923), Sonic (146), BOB (60808), Berachain (80094).

### State Persistence
The `state/` directory stores serialized account state per chain so the bot can resume without re-scanning all historical events.

### Contracts (`contracts/`)
- **`Liquidator.sol`** — Main on-chain executor; called with collateral/liability vault addresses, violator address, and encoded swap data
- **`ISwapper.sol`** — Interface the Liquidator calls to swap seized collateral for debt repayment
- **`SwapVerifier.sol`** — Verifies swap output meets minimum amounts
- ABIs for EVault, EVC, EulerRouter, oracle interfaces are in `contracts/*.json`

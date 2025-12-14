# polyLoop

A decentralized lending protocol built on top of Polymarket, enabling users to borrow against their conditional token positions.

## Overview

polyLoop allows users to deposit Polymarket conditional tokens (YES positions) as collateral and borrow USDC against them. The protocol includes automated liquidation mechanisms and integrates with Polymarket's conditional token system for efficient position management.

## Features

- **Collateralized Lending**: Deposit Polymarket YES tokens as collateral to borrow USDC
- **LTV Management**: Borrow up to 50% LTV with automatic liquidation at 77% LTV
- **Liquidation System**: Automated liquidation mechanism that merges YES and NO positions
- **Interest Accrual**: Configurable interest rates with block-based accrual (PolyManager)
- **Liquidity Layer**: ERC4626-based vault system for managing protocol liquidity

## Architecture

### Core Contracts

- **`Market.sol`** (MarketPOC): Proof-of-concept market contract for lending against Polymarket positions
- **`PolyManager.sol`**: Full-featured lending manager with interest accrual and health factors
- **`LiqLayer.sol`**: ERC4626 liquidity vault that provides funds to markets

### Key Components

1. **Position Management**: Tracks user collateral, debt, and last updated block
2. **LTV Calculation**: Real-time loan-to-value ratio monitoring
3. **Liquidation**: Automatic liquidation when positions become undercollateralized
4. **Conditional Token Integration**: Seamless interaction with Polymarket's conditional token system

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Solidity ^0.8.0

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd polyLoop

# Install dependencies
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test
```

## Usage

### MarketPOC Contract

The `MarketPOC` contract provides basic lending functionality:

- **Deposit Collateral**: Deposit YES tokens as collateral
- **Borrow**: Borrow USDC up to 50% LTV
- **Repay**: Repay borrowed USDC
- **Withdraw**: Withdraw collateral (maintaining LTV requirements)
- **Liquidate**: Liquidate undercollateralized positions

### PolyManager Contract

The `PolyManager` contract provides advanced features:

- Configurable borrow and liquidation LTV thresholds
- Interest rate accrual per block
- Health factor calculations
- Liquidation bonuses

## Contract Addresses (Polygon)

- **USDC**: `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174`
- **Polymarket Conditional Tokens**: `0x4D97DCd97eC945f40cF65F87097ACe5EA0476045`

## Security

⚠️ **This is a proof-of-concept implementation. Do not use in production without comprehensive security audits.**

## License

MIT


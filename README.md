# polyLoop

A decentralized lending protocol built on top of Polymarket, enabling users to borrow USDC against their Polymarket conditional token positions.

## Table of Contents

- [Overview](#overview)
- [How the Protocol Works](#how-the-protocol-works)
  - [Core Architecture](#core-architecture)
  - [Contract Interactions](#contract-interactions)
  - [Liquidity Flow](#liquidity-flow)
- [Key Components](#key-components)
  - [Market.sol](#marketsol)
  - [CoreVault.sol](#corevaultsol)
  - [CoreStrategy.sol](#corestrategysol)
  - [MarketFactory.sol](#marketfactorysol)
- [Protocol Mechanics](#protocol-mechanics)
  - [Depositing Collateral](#depositing-collateral)
  - [Borrowing](#borrowing)
  - [Interest Accrual](#interest-accrual)
  - [Repayment](#repayment)
  - [Liquidations](#liquidations)
- [Risk Parameters](#risk-parameters)
- [Getting Started](#getting-started)
- [Security](#security)

## Overview

polyLoop is a lending protocol that unlocks liquidity from Polymarket prediction market positions. Users can deposit their Polymarket conditional tokens (YES positions) as collateral and borrow USDC against them. The protocol features:

- **Collateralized Lending**: Deposit Polymarket conditional tokens to borrow USDC
- **Multi-Market Support**: Factory pattern allows creation of markets for different Polymarket events
- **ERC4626 Vault System**: Standardized liquidity management with optional yield strategies
- **Oracle-Based Pricing**: Chainlink price feeds for accurate collateral valuation
- **Automated Liquidations**: Protect lenders through health factor monitoring and liquidation incentives
- **Interest Accrual**: Time-based interest calculation on borrowed amounts

## How the Protocol Works

### Core Architecture

The protocol consists of three main layers:

```
┌─────────────────────────────────────────────────────────────┐
│                         Users                                │
│  (Borrowers, Lenders, Liquidators)                          │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│                    Market Layer                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  MarketFactory.sol                                    │   │
│  │  - Creates and manages Market instances              │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Market.sol (per Polymarket event)                   │   │
│  │  - Manages collateral deposits                       │   │
│  │  - Handles borrowing/repayment                       │   │
│  │  - Calculates health factors                         │   │
│  │  - Executes liquidations                             │   │
│  └──────────────────────────────────────────────────────┘   │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│                  Liquidity Layer                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  CoreVault.sol (ERC4626)                             │   │
│  │  - Manages USDC liquidity pool                       │   │
│  │  - Tracks borrowed amounts                           │   │
│  │  - Issues vault shares to lenders                    │   │
│  │  - Handles bad debt                                  │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  CoreStrategy.sol (Optional)                         │   │
│  │  - Extends CoreVault with yield strategies          │   │
│  │  - Deploys idle funds to external protocols         │   │
│  └──────────────────────────────────────────────────────┘   │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│              External Integrations                           │
│  - Polymarket CTF (Conditional Token Framework)             │
│  - Chainlink Price Feeds                                    │
│  - USDC Token                                               │
│  - External Yield Strategies (optional)                     │
└─────────────────────────────────────────────────────────────┘
```

### Contract Interactions

#### 1. **Lender Flow** (Providing Liquidity)

```
Lender → CoreVault.deposit(USDC)
         ↓
CoreVault mints vault shares (ERC4626)
         ↓
USDC sits in vault, available for borrowing
         ↓
(Optional) CoreStrategy deploys to yield strategies
```

#### 2. **Borrower Flow** (Taking Loans)

```
Borrower → Market.deposit(Polymarket Tokens)
           ↓
Market stores collateral (ERC1155)
           ↓
Borrower → Market.borrow(amount)
           ↓
Market checks LTV ratio & health factor
           ↓
Market → CoreVault.borrowLiq(amount, borrower)
         ↓
CoreVault transfers USDC to borrower
CoreVault increments totalBorrowed
```

#### 3. **Repayment Flow**

```
Borrower → Market.repay(amount)
           ↓
Market accrues interest on debt
           ↓
Market transfers USDC from borrower
           ↓
Market → CoreVault.repayLiq(amount)
         ↓
CoreVault decrements totalBorrowed
CoreVault receives USDC back
```

#### 4. **Liquidation Flow**

```
Liquidator monitors positions
           ↓
Position health factor < liquidationThreshold
           ↓
Liquidator → Market.liquidate(borrower, repayAmount)
             ↓
Market calculates collateral to seize (with discount)
             ↓
Market transfers USDC from liquidator
             ↓
If collateral value < debt:
    Market → CoreVault.badDebt(actualDebt, recoveredAmount)
Else:
    Market → CoreVault.repayLiq(repayAmount)
             ↓
Market transfers seized collateral to liquidator
```

### Liquidity Flow

```
USDC Flow:
Lenders → CoreVault → Markets → Borrowers
                ↑         ↓
                └─────────┘
              (Repayments)

Collateral Flow:
Borrowers → Market (holds Polymarket tokens)
              ↓
         Liquidators (if undercollateralized)
```

## Key Components

### Market.sol

**Purpose**: Individual lending market for a specific Polymarket conditional token.

**Key Responsibilities**:
- **Collateral Management**: Accepts and holds Polymarket conditional tokens (ERC1155)
- **Position Tracking**: Maintains each user's collateral amount, borrowed amount, and last interest update timestamp
- **Borrow Logic**: Validates LTV ratios and facilitates USDC borrowing from CoreVault
- **Interest Calculation**: Accrues interest on borrowed amounts based on time elapsed
- **Health Monitoring**: Calculates health factors to determine liquidation eligibility
- **Liquidation Execution**: Seizes collateral and repays debt when positions become unhealthy
- **Oracle Integration**: Uses Chainlink price feeds to value collateral in USDC terms

**Key State Variables**:
```solidity
struct Position {
    uint256 collateralAmount;      // Polymarket tokens deposited
    uint256 borrowedAmount;        // USDC borrowed (with accrued interest)
    uint256 lastInterestUpdate;    // Timestamp of last interest accrual
}

mapping(address => Position) public positions;
```

**Configuration Parameters** (immutable, set at deployment):
- `collateralTokenId`: The specific Polymarket token ID accepted as collateral
- `interestRatePerYear`: Annual interest rate in basis points (e.g., 500 = 5%)
- `ltvRatio`: Maximum loan-to-value ratio (e.g., 5000 = 50%)
- `liquidationThreshold`: LTV at which liquidation becomes possible (e.g., 7700 = 77%)
- `liquidationDiscount`: Bonus for liquidators (e.g., 500 = 5% discount on collateral)

**How It Works**:

1. **Deposit**: Users transfer Polymarket tokens to the Market contract, which tracks their collateral balance.

2. **Borrow**: 
   - Market checks if `newDebt <= (collateralValue * ltvRatio) / 10000`
   - If valid, calls `CoreVault.borrowLiq()` to transfer USDC to user
   - Updates user's `borrowedAmount`

3. **Interest Accrual**:
   ```solidity
   interest = (borrowedAmount * interestRatePerYear * timeElapsed) / (10000 * SECONDS_PER_YEAR)
   ```
   - Interest compounds into the principal on each interaction

4. **Health Factor**:
   ```solidity
   healthFactor = (collateralValue * 10000) / debtWithInterest
   ```
   - If `healthFactor < liquidationThreshold`, position can be liquidated

5. **Liquidation**:
   - Liquidator repays part/all of the debt
   - Receives collateral worth `debtRepaid + liquidationDiscount`
   - If collateral value < debt (bad debt), Market calls `CoreVault.badDebt()`

### CoreVault.sol

**Purpose**: ERC4626-compliant vault that manages the USDC liquidity pool for all markets.

**Key Responsibilities**:
- **Liquidity Pool**: Holds USDC deposits from lenders
- **Share Accounting**: Issues vault shares (ERC20) representing lender ownership
- **Market Authorization**: Whitelist of approved Market contracts that can borrow
- **Borrow Tracking**: Tracks total USDC borrowed across all markets
- **Bad Debt Handling**: Absorbs losses when liquidations don't fully cover debt

**Key State Variables**:
```solidity
uint256 public totalBorrowed;              // Total USDC lent out to markets
mapping(address => bool) public markets;   // Approved market contracts
```

**How It Works**:

1. **Deposit (ERC4626)**:
   - Lenders deposit USDC
   - Vault mints shares based on current exchange rate
   - `shares = (assets * totalSupply) / totalAssets()`

2. **Total Assets Calculation**:
   ```solidity
   totalAssets = USDC_balance + totalBorrowed
   ```
   - Includes both idle USDC and USDC lent to markets
   - This ensures share value increases as interest is repaid

3. **Borrow (Market → Vault)**:
   - Only whitelisted markets can call `borrowLiq()`
   - Vault transfers USDC to borrower
   - Increments `totalBorrowed`
   - Reduces idle USDC balance

4. **Repay (Market → Vault)**:
   - Market transfers USDC back to vault
   - Decrements `totalBorrowed`
   - Increases idle USDC balance
   - Share value increases (lenders earn yield)

5. **Bad Debt**:
   - When liquidation doesn't cover full debt
   - Market calls `badDebt(actualDebt, recoveredAmount)`
   - Vault decrements `totalBorrowed` by full debt
   - Only receives partial repayment
   - Loss is socialized across all vault share holders

6. **Withdraw (ERC4626)**:
   - Lenders redeem shares for USDC
   - Can only withdraw idle USDC (not borrowed funds)
   - `assets = (shares * totalAssets) / totalSupply`

### CoreStrategy.sol

**Purpose**: Extended version of CoreVault that can deploy idle funds to external yield strategies.

**Key Responsibilities**:
- **Yield Optimization**: Deploys idle USDC to external protocols (e.g., Aave, Compound)
- **Strategy Management**: Controls when to deposit/withdraw from strategies
- **Enhanced Returns**: Generates additional yield for lenders beyond interest from borrowers

**Key State Variables**:
```solidity
address public strategy;    // External yield strategy contract
bool public onStrat;        // Whether funds are currently deployed
```

**How It Works**:

1. **Inherits CoreVault**: All core functionality remains the same

2. **Deploy to Strategy**:
   ```solidity
   deposit() → IStrategy(strategy).deposit()
   ```
   - Transfers idle USDC to external strategy
   - Strategy invests in yield-bearing protocols

3. **Withdraw from Strategy**:
   ```solidity
   withdraw() → IStrategy(strategy).withdraw()
   ```
   - Pulls USDC back from strategy
   - Needed when borrowers need liquidity

4. **Enhanced Total Assets**:
   ```solidity
   totalAssets = USDC_balance + totalBorrowed + strategyBalance
   ```
   - Includes funds deployed to strategies
   - Share value increases from both borrower interest AND strategy yields

**Strategy Interface**:
```solidity
interface IStrategy {
    function deposit() external;           // Deploy funds
    function withdraw() external;          // Retrieve funds
    function balance() external view returns (uint256);  // Current balance
}
```

### MarketFactory.sol

**Purpose**: Factory contract for deploying new Market instances.

**Key Responsibilities**:
- **Market Deployment**: Creates new Market contracts for different Polymarket events
- **Market Registry**: Tracks all deployed markets
- **Parameter Validation**: Ensures markets are created with valid risk parameters
- **Access Control**: Only owner can create new markets

**How It Works**:

1. **Create Market**:
   ```solidity
   createMarket(
       priceFeed,              // Chainlink oracle for this token
       tokenId,                // Polymarket token ID
       interestRatePerYear,    // e.g., 500 = 5% APY
       ltvRatio,               // e.g., 5000 = 50% max LTV
       liquidationThreshold,   // e.g., 7700 = 77% liquidation LTV
       liquidationDiscount     // e.g., 500 = 5% liquidator bonus
   )
   ```

2. **Validation**:
   - Ensures `ltvRatio < liquidationThreshold < 10000`
   - Validates price feed address
   - Checks interest rate is non-zero

3. **Deployment**:
   - Deploys new Market contract with specified parameters
   - Adds to `allMarkets` array
   - Marks as valid market in `isMarket` mapping

4. **Registry**:
   - `getAllMarkets()`: Returns all deployed markets
   - `getMarket(index)`: Get market by index
   - `isMarket[address]`: Check if address is a valid market

## Protocol Mechanics

### Depositing Collateral

**User Action**: Transfer Polymarket conditional tokens to Market

**Process**:
1. User approves Market contract to transfer their ERC1155 tokens
2. User calls `Market.deposit(amount)`
3. Market transfers tokens from user via `safeTransferFrom`
4. Market increments user's `position.collateralAmount`
5. Market initializes `position.lastInterestUpdate` if first deposit

**Requirements**:
- Amount > 0
- User must own the tokens
- Tokens must match the Market's `collateralTokenId`

### Borrowing

**User Action**: Borrow USDC against deposited collateral

**Process**:
1. User calls `Market.borrow(amount)`
2. Market accrues any pending interest on existing debt
3. Market calculates maximum borrowable amount:
   ```
   collateralValue = (collateralAmount * oraclePrice) / 1e20
   maxBorrow = (collateralValue * ltvRatio) / 10000
   ```
4. Market validates `newTotalDebt <= maxBorrow`
5. Market calls `CoreVault.borrowLiq(amount, user)`
6. CoreVault transfers USDC to user
7. Market updates `position.borrowedAmount`

**Requirements**:
- User has deposited collateral
- New total debt doesn't exceed LTV limit
- CoreVault has sufficient USDC liquidity

**Example**:
- User deposits 1000 Polymarket tokens
- Oracle price: $0.60 per token
- Collateral value: $600
- LTV ratio: 50%
- Max borrow: $300 USDC

### Interest Accrual

**Mechanism**: Simple interest calculated based on time elapsed

**Formula**:
```solidity
timeElapsed = currentTimestamp - lastInterestUpdate
interestAccrued = (borrowedAmount * interestRatePerYear * timeElapsed) / (10000 * SECONDS_PER_YEAR)
newDebt = borrowedAmount + interestAccrued
```

**Accrual Triggers**:
- Every time user borrows more
- Every time user repays
- Every time user withdraws collateral
- During liquidation checks
- When viewing position (read-only calculation)

**Example**:
- Borrowed: 100 USDC
- Interest rate: 10% per year (1000 basis points)
- Time elapsed: 30 days
- Interest: (100 * 1000 * 2592000) / (10000 * 31536000) ≈ 0.82 USDC
- New debt: 100.82 USDC

### Repayment

**User Action**: Repay borrowed USDC plus accrued interest

**Process**:
1. User calls `Market.repay(amount)`
2. Market accrues interest to get current debt
3. Market determines actual repayment (min of amount and total debt)
4. User transfers USDC to Market
5. Market approves CoreVault to spend USDC
6. Market calls `CoreVault.repayLiq(repayAmount)`
7. Market decrements `position.borrowedAmount`
8. Market updates `position.lastInterestUpdate`

**Partial vs Full Repayment**:
- If `amount >= totalDebt`: Full repayment, position cleared
- If `amount < totalDebt`: Partial repayment, remaining debt continues accruing interest

**Requirements**:
- User has outstanding debt
- User has approved Market to transfer USDC

### Liquidations

**Trigger**: Position becomes undercollateralized

**Liquidation Condition**:
```solidity
debt = borrowedAmount + accruedInterest
collateralValue = (collateralAmount * oraclePrice) / 1e20
maxDebtBeforeLiquidation = (collateralValue * liquidationThreshold) / 10000

isLiquidatable = debt > maxDebtBeforeLiquidation
```

**Process**:
1. Liquidator identifies unhealthy position
2. Liquidator calls `Market.liquidate(borrower, repayAmount)`
3. Market validates position is liquidatable
4. Market calculates collateral to seize:
   ```
   collateralValue = (repayAmount * 1e20) / oraclePrice
   collateralWithDiscount = collateralValue * (1 + liquidationDiscount)
   ```
5. Liquidator transfers USDC to Market
6. Market transfers seized collateral to liquidator
7. Market updates borrower's position

**Bad Debt Scenario**:
If `collateralValue < debtRepaid`:
- Market calls `CoreVault.badDebt(actualDebt, recoveredAmount)`
- CoreVault absorbs the loss
- Loss is socialized among all vault share holders

**Liquidation Incentive**:
- Liquidators receive collateral at a discount (e.g., 5%)
- If repaying $100 debt with 5% discount:
  - Liquidator pays: $100
  - Liquidator receives: $105 worth of collateral
  - Profit: $5 (minus gas costs)

**Example**:
- Borrower has 1000 tokens, borrowed 300 USDC
- Initial price: $0.60, collateral value: $600
- Price drops to $0.45, collateral value: $450
- Debt with interest: $305
- Liquidation threshold: 77%
- Max debt at 77%: $450 * 0.77 = $346.50
- Current debt ($305) < $346.50 → Not liquidatable yet
- If debt grows to $350 or price drops further → Liquidatable

## Risk Parameters

### LTV Ratio (Loan-to-Value)
- **Definition**: Maximum percentage of collateral value that can be borrowed
- **Typical Range**: 40-60% (4000-6000 basis points)
- **Example**: 50% LTV means $100 collateral → max $50 borrow

### Liquidation Threshold
- **Definition**: LTV at which position becomes liquidatable
- **Typical Range**: 70-85% (7000-8500 basis points)
- **Must Be**: Greater than LTV ratio
- **Example**: 77% threshold means position liquidatable when debt reaches 77% of collateral value

### Liquidation Discount
- **Definition**: Bonus percentage liquidators receive
- **Typical Range**: 5-10% (500-1000 basis points)
- **Purpose**: Incentivizes liquidators to act quickly
- **Example**: 5% discount means liquidator gets $105 collateral for $100 debt repaid

### Interest Rate
- **Definition**: Annual percentage rate charged on borrowed amounts
- **Typical Range**: 5-20% (500-2000 basis points)
- **Accrual**: Continuous, calculated per second
- **Example**: 10% APR on $100 = ~$10 interest per year

### Safety Buffer
The gap between LTV and liquidation threshold provides a safety buffer:
```
Safety Buffer = Liquidation Threshold - LTV Ratio
Example: 77% - 50% = 27% buffer
```

This buffer protects against:
- Price volatility
- Oracle delays
- Interest accrual between user actions




## Contract Addresses (Polygon)

- **USDC**: `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174`
- **Polymarket Conditional Tokens**: `0x4D97DCd97eC945f40cF65F87097ACe5EA0476045`

## Security

⚠️ **This is an experimental protocol. Use at your own risk.**

### Known Risks

1. **Oracle Dependency**: Relies on Chainlink price feeds for collateral valuation
2. **Polymarket Risk**: Collateral value tied to prediction market outcomes
3. **Liquidation Risk**: Rapid price movements may cause liquidations
4. **Smart Contract Risk**: Code has not been audited
5. **Bad Debt Risk**: Vault share holders absorb losses from undercollateralized liquidations

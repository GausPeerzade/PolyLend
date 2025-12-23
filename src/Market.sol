// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICoreVault} from "./interfaces/ICoreVault.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

contract Market is IERC1155Receiver, ReentrancyGuard {
    ICoreVault public immutable coreVault;
    IERC1155 public immutable polymarketCTF;
    IERC20 public immutable usdcToken;
    AggregatorV3Interface public immutable priceFeed;
    
    uint256 public immutable collateralTokenId;
    uint256 public immutable interestRatePerYear;
    uint256 public immutable ltvRatio;
    uint256 public immutable liquidationThreshold;
    uint256 public immutable liquidationDiscount;
    
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    
    struct Position {
        uint256 collateralAmount;
        uint256 borrowedAmount;
        uint256 lastInterestUpdate;
    }
    
    mapping(address => Position) public positions;
    
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount, uint256 interest);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 collateralSeized,
        uint256 debtRepaid
    );
    
    error InsufficientCollateral();
    error ExceedsMaxBorrow();
    error InsufficientBorrow();
    error NotLiquidatable();
    error InsufficientBalance();
    error InvalidAmount();
    error Unauthorized();
    error StalePrice();
    error InvalidPrice();
    
    constructor(
        address _coreVault,
        address _polymarketCTF,
        address _priceFeed,
        uint256 _collateralTokenId,
        uint256 _interestRatePerYear,
        uint256 _ltvRatio,
        uint256 _liquidationThreshold,
        uint256 _liquidationDiscount
    ) {
        coreVault = ICoreVault(_coreVault);
        polymarketCTF = IERC1155(_polymarketCTF);
        usdcToken = IERC20(ICoreVault(_coreVault).asset());
        priceFeed = AggregatorV3Interface(_priceFeed);
        collateralTokenId = _collateralTokenId;
        interestRatePerYear = _interestRatePerYear;
        ltvRatio = _ltvRatio;
        liquidationThreshold = _liquidationThreshold;
        liquidationDiscount = _liquidationDiscount;
    }
    
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        Position storage position = positions[msg.sender];
        
        polymarketCTF.safeTransferFrom(
            msg.sender,
            address(this),
            collateralTokenId,
            amount,
            ""
        );
        
        position.collateralAmount += amount;
        
        if (position.lastInterestUpdate == 0) {
            position.lastInterestUpdate = block.timestamp;
        }
        
        emit Deposit(msg.sender, amount);
    }
    
    function withdraw(uint256 amount) external nonReentrant {
        Position storage position = positions[msg.sender];
        
        if (amount == 0) revert InvalidAmount();
        if (position.collateralAmount < amount) revert InsufficientBalance();
        
        _accrueInterest(msg.sender);
        
        uint256 newCollateral = position.collateralAmount - amount;
        uint256 maxBorrow = _calculateMaxBorrow(newCollateral);
        
        if (position.borrowedAmount > maxBorrow) revert InsufficientCollateral();
        
        position.collateralAmount = newCollateral;
        
        polymarketCTF.safeTransferFrom(
            address(this),
            msg.sender,
            collateralTokenId,
            amount,
            ""
        );
        
        emit Withdraw(msg.sender, amount);
    }
    
    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        Position storage position = positions[msg.sender];
        
        if (position.collateralAmount == 0) revert InsufficientCollateral();
        
        _accrueInterest(msg.sender);
        
        uint256 maxBorrow = _calculateMaxBorrow(position.collateralAmount);
        uint256 newBorrowAmount = position.borrowedAmount + amount;
        
        if (newBorrowAmount > maxBorrow) revert ExceedsMaxBorrow();
        
        position.borrowedAmount = newBorrowAmount;
        
        coreVault.borrowLiq(amount, msg.sender);
        
        emit Borrow(msg.sender, amount);
    }
    
    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        Position storage position = positions[msg.sender];
        
        _accrueInterest(msg.sender);
        
        if (position.borrowedAmount == 0) revert InsufficientBorrow();
        
        uint256 repayAmount = amount > position.borrowedAmount 
            ? position.borrowedAmount 
            : amount;
        
        uint256 interest = repayAmount > position.borrowedAmount 
            ? 0 
            : position.borrowedAmount - repayAmount;
        
        position.borrowedAmount -= repayAmount;
        position.lastInterestUpdate = block.timestamp;
        
        usdcToken.transferFrom(msg.sender, address(this), repayAmount);
        
        usdcToken.approve(address(coreVault), repayAmount);
        
        coreVault.repayLiq(repayAmount);
        
        emit Repay(msg.sender, repayAmount, interest);
    }
    
    function liquidate(address borrower, uint256 repayAmount) external nonReentrant {
        if (borrower == msg.sender) revert Unauthorized();
        
        Position storage position = positions[borrower];
        
        _accrueInterest(borrower);
        
        if (!_isLiquidatable(borrower)) revert NotLiquidatable();
        
        uint256 debtToRepay = repayAmount > position.borrowedAmount 
            ? position.borrowedAmount 
            : repayAmount;
        
        uint256 price = getLatestPrice();
        uint256 collateralValue = (debtToRepay * 1e20) / price;
        uint256 collateralWithDiscount = (collateralValue * (BASIS_POINTS + liquidationDiscount)) / BASIS_POINTS;
        
        if (collateralWithDiscount > position.collateralAmount) {
            collateralWithDiscount = position.collateralAmount;
        }
        
        position.borrowedAmount -= debtToRepay;
        position.collateralAmount -= collateralWithDiscount;
        
        usdcToken.transferFrom(msg.sender, address(this), debtToRepay);
        
        uint256 collateralValueRecovered = (collateralWithDiscount * price) / 1e20;
        
        if (collateralValueRecovered < debtToRepay) {
            usdcToken.approve(address(coreVault), collateralValueRecovered);
            coreVault.badDebt(debtToRepay, collateralValueRecovered);
        } else {
            usdcToken.approve(address(coreVault), debtToRepay);
            coreVault.repayLiq(debtToRepay);
        }
        
        polymarketCTF.safeTransferFrom(
            address(this),
            msg.sender,
            collateralTokenId,
            collateralWithDiscount,
            ""
        );
        
        emit Liquidate(msg.sender, borrower, collateralWithDiscount, debtToRepay);
    }
    
    function getPosition(address user) external view returns (
        uint256 collateral,
        uint256 debt,
        uint256 healthFactor
    ) {
        Position memory position = positions[user];
        collateral = position.collateralAmount;
        debt = _calculateDebtWithInterest(user);
        
        if (debt == 0) {
            healthFactor = type(uint256).max;
        } else {
            uint256 price = getLatestPrice();
            uint256 collateralValue = (collateral * price) / 1e20;
            healthFactor = (collateralValue * BASIS_POINTS) / debt;
        }
    }
    
    function getLatestPrice() public view returns (uint256) {
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        
        if (block.timestamp > updatedAt + 3600) revert StalePrice();
        
        if (answeredInRound < roundId) revert StalePrice();
        
        if (price <= 0) revert InvalidPrice();
        
        return uint256(price);
    }
    
    function _calculateMaxBorrow(uint256 collateralAmount) internal view returns (uint256) {
        uint256 price = getLatestPrice();
        
        uint256 collateralValue = (collateralAmount * price) / 1e20;
        
        return (collateralValue * ltvRatio) / BASIS_POINTS;
    }
    
    function _calculateDebtWithInterest(address user) internal view returns (uint256) {
        Position memory position = positions[user];
        
        if (position.borrowedAmount == 0) return 0;
        
        uint256 timeElapsed = block.timestamp - position.lastInterestUpdate;
        uint256 interestAccrued = (position.borrowedAmount * interestRatePerYear * timeElapsed) 
            / (BASIS_POINTS * SECONDS_PER_YEAR);
        
        return position.borrowedAmount + interestAccrued;
    }
    
    function _accrueInterest(address user) internal {
        Position storage position = positions[user];
        
        if (position.borrowedAmount == 0) return;
        
        uint256 newDebt = _calculateDebtWithInterest(user);
        position.borrowedAmount = newDebt;
        position.lastInterestUpdate = block.timestamp;
    }
    
    function _isLiquidatable(address user) internal view returns (bool) {
        Position memory position = positions[user];
        
        if (position.borrowedAmount == 0) return false;
        
        uint256 debt = _calculateDebtWithInterest(user);
        uint256 price = getLatestPrice();
        uint256 collateralValue = (position.collateralAmount * price) / 1e20;
        uint256 maxDebt = (collateralValue * liquidationThreshold) / BASIS_POINTS;
        
        return debt > maxDebt;
    }
    
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
    
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}

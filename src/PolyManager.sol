// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./LiqLayer.sol";

contract PolyManager {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;

    IERC20 public immutable collateralToken;
    IERC20 public immutable borrowToken;
    LiqLayer public immutable liqLayer;

    uint256 public immutable borrowLTV;
    uint256 public immutable liquidationLTV;
    uint256 public immutable interestRatePerBlock;
    uint256 public immutable liquidationBonus;

    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public borrowPrincipal;
    mapping(address => uint256) public originalPrincipal;
    mapping(address => uint256) public borrowBlock;
    uint256 public totalBorrowed;

    // Errors
    error InsufficientCollateral();
    error ExceedsBorrowLimit();
    error NotLiquidatable();
    error InsufficientRepay();
    error TransferFailed();
    error ZeroAmount();
    error InvalidLTV();
    error NoDebt();

    // Events
    event CollateralDeposited(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount, uint256 interest);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        uint256 repayAmount,
        uint256 collateralSeized
    );

    constructor(
        address _collateralToken,
        address _borrowToken,
        address _liqLayer,
        uint256 _borrowLTV,
        uint256 _liquidationLTV,
        uint256 _interestRatePerBlock,
        uint256 _liquidationBonus
    ) {
        if (_borrowLTV >= _liquidationLTV || _liquidationLTV > BASIS_POINTS) {
            revert InvalidLTV();
        }

        collateralToken = IERC20(_collateralToken);
        borrowToken = IERC20(_borrowToken);
        liqLayer = LiqLayer(_liqLayer);
        borrowLTV = _borrowLTV;
        liquidationLTV = _liquidationLTV;
        interestRatePerBlock = _interestRatePerBlock;
        liquidationBonus = _liquidationBonus;
    }

    function getBorrowBalance(address user) public view returns (uint256) {
        uint256 principal = borrowPrincipal[user];
        if (principal == 0) return 0;

        uint256 blocksElapsed = block.number - borrowBlock[user];
        if (blocksElapsed == 0) return principal;

        uint256 interest = (principal * interestRatePerBlock * blocksElapsed) /
            BASIS_POINTS;
        return principal + interest;
    }

    function getHealthFactor(address user) public view returns (uint256) {
        uint256 debt = getBorrowBalance(user);
        if (debt == 0) return type(uint256).max;

        uint256 collateral = collateralBalance[user];
        if (collateral == 0) return 0;

        return (collateral * BASIS_POINTS) / debt;
    }

    function isLiquidatable(address user) public view returns (bool) {
        uint256 healthFactor = getHealthFactor(user);
        return healthFactor < liquidationLTV;
    }

    function depositCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        collateralBalance[msg.sender] += amount;

        emit CollateralDeposited(msg.sender, amount);
    }

    function borrow(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        if (borrowPrincipal[msg.sender] > 0) {
            _updateInterest(msg.sender);
        }

        uint256 currentDebt = borrowPrincipal[msg.sender];
        uint256 newDebt = currentDebt + amount;
        uint256 collateral = collateralBalance[msg.sender];

        if (newDebt * BASIS_POINTS > collateral * borrowLTV) {
            revert ExceedsBorrowLimit();
        }

        if (borrowPrincipal[msg.sender] > 0) {
            uint256 principal = borrowPrincipal[msg.sender];
            uint256 blocksElapsed = block.number - borrowBlock[msg.sender];
            if (blocksElapsed > 0) {
                uint256 interest = (principal *
                    interestRatePerBlock *
                    blocksElapsed) / BASIS_POINTS;
                borrowPrincipal[msg.sender] = principal + interest;
            }
        }

        liqLayer.borrowLiq(amount, msg.sender);

        borrowPrincipal[msg.sender] += amount;
        originalPrincipal[msg.sender] += amount;
        borrowBlock[msg.sender] = block.number;
        totalBorrowed += amount;

        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        _updateInterest(msg.sender);

        uint256 currentDebt = borrowPrincipal[msg.sender];
        if (currentDebt == 0) revert NoDebt();

        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;
        uint256 originalPrincipalBefore = originalPrincipal[msg.sender];

        uint256 originalPrincipalRepaid = (repayAmount *
            originalPrincipalBefore) / currentDebt;
        uint256 interestRepaid = repayAmount - originalPrincipalRepaid;

        borrowToken.safeTransferFrom(msg.sender, address(this), repayAmount);

        borrowPrincipal[msg.sender] -= repayAmount;
        originalPrincipal[msg.sender] -= originalPrincipalRepaid;
        borrowBlock[msg.sender] = block.number;
        totalBorrowed -= originalPrincipalRepaid;

        if (originalPrincipalRepaid > 0) {
            borrowToken.forceApprove(
                address(liqLayer),
                originalPrincipalRepaid
            );
            liqLayer.repayLiq(originalPrincipalRepaid);
        }

        emit Repaid(msg.sender, repayAmount, interestRepaid);
    }

    function withdrawCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (amount > collateralBalance[msg.sender]) {
            revert InsufficientCollateral();
        }

        _updateInterest(msg.sender);

        uint256 remainingCollateral = collateralBalance[msg.sender] - amount;
        uint256 currentDebt = borrowPrincipal[msg.sender];

        if (currentDebt > 0) {
            if (currentDebt * BASIS_POINTS > remainingCollateral * borrowLTV) {
                revert ExceedsBorrowLimit();
            }
        }

        collateralBalance[msg.sender] = remainingCollateral;
        collateralToken.safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, amount);
    }

    function liquidate(address user, uint256 repayAmount) external {
        if (repayAmount == 0) revert ZeroAmount();
        if (!isLiquidatable(user)) revert NotLiquidatable();

        _updateInterest(user);

        uint256 currentDebt = borrowPrincipal[user];
        if (repayAmount > currentDebt) {
            repayAmount = currentDebt;
        }

        uint256 originalPrincipalBefore = originalPrincipal[user];

        uint256 originalPrincipalRepaid = (repayAmount *
            originalPrincipalBefore) / currentDebt;
        uint256 interestRepaid = repayAmount - originalPrincipalRepaid;

        uint256 collateralSeized = (repayAmount *
            (BASIS_POINTS + liquidationBonus)) / BASIS_POINTS;

        if (collateralSeized > collateralBalance[user]) {
            collateralSeized = collateralBalance[user];
        }

        borrowToken.safeTransferFrom(msg.sender, address(this), repayAmount);

        if (originalPrincipalRepaid > 0) {
            borrowToken.forceApprove(
                address(liqLayer),
                originalPrincipalRepaid
            );
            liqLayer.repayLiq(originalPrincipalRepaid);
        }

        borrowPrincipal[user] -= repayAmount;
        originalPrincipal[user] -= originalPrincipalRepaid;
        borrowBlock[user] = block.number;
        totalBorrowed -= originalPrincipalRepaid;
        collateralBalance[user] -= collateralSeized;

        collateralToken.safeTransfer(msg.sender, collateralSeized);

        emit Liquidated(user, msg.sender, repayAmount, collateralSeized);
    }

    function _updateInterest(address user) internal {
        uint256 principal = borrowPrincipal[user];
        if (principal == 0) return;

        uint256 blocksElapsed = block.number - borrowBlock[user];
        if (blocksElapsed == 0) return;

        uint256 interest = (principal * interestRatePerBlock * blocksElapsed) /
            BASIS_POINTS;

        borrowPrincipal[user] = principal + interest;
        borrowBlock[user] = block.number;
    }

    function getCollateralBalance(
        address user
    ) external view returns (uint256) {
        return collateralBalance[user];
    }

    function getBorrowPrincipal(address user) external view returns (uint256) {
        return borrowPrincipal[user];
    }

    function getOriginalPrincipal(
        address user
    ) external view returns (uint256) {
        return originalPrincipal[user];
    }
}

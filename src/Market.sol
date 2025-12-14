// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "./interfaces/IPolyMarket.sol";
import "./LiqLayer.sol";

contract MarketPOC is ERC1155Holder {
    IERC20 public constant USDC =
        IERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    IPolyMarket public constant CONDITIONAL_TOKENS =
        IPolyMarket(0x4D97DCd97eC945f40cF65F87097ACe5EA0476045);

    address public immutable liqLayer;

    mapping(address => Position) public positions;

    bytes32 public conditionId;
    bytes32 public parentCollectionId = bytes32(0);
    bytes32 public collectionIdYes;
    bytes32 public collectionIdNo;
    uint256 public positionIdYes;
    uint256 public positionIdNo;

    address public owner;
    uint256 public mockPrice;

    struct Position {
        uint256 collateralBalance;
        uint256 debt;
        uint256 lastUpdatedBlock;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(
        bytes32 _conditionId,
        uint256 _initialPrice,
        address _liqLayer
    ) {
        owner = msg.sender;
        liqLayer = _liqLayer;
        conditionId = _conditionId;
        collectionIdYes = keccak256(
            abi.encodePacked(parentCollectionId, conditionId, uint256(1))
        );
        collectionIdNo = keccak256(
            abi.encodePacked(parentCollectionId, conditionId, uint256(2))
        );
        positionIdYes = uint256(
            keccak256(abi.encodePacked(address(USDC), collectionIdYes))
        );
        positionIdNo = uint256(
            keccak256(abi.encodePacked(address(USDC), collectionIdNo))
        );

        mockPrice = _initialPrice;
    }

    function setMockPrice(uint256 _price) external onlyOwner {
        mockPrice = _price;
    }

    function getLTV(address _user) public view returns (uint256) {
        Position memory position = positions[_user];
        if (position.collateralBalance == 0) return 0;
        uint256 collValue = (position.collateralBalance * mockPrice) / 1e18;
        if (collValue == 0) return type(uint256).max;
        return (position.debt * 100) / collValue;
    }

    function depositCollateral(uint256 amount, address _user) external {
        CONDITIONAL_TOKENS.safeTransferFrom(
            msg.sender,
            address(this),
            positionIdYes,
            amount,
            ""
        );
        Position storage position = positions[_user];
        position.collateralBalance += amount;
        position.lastUpdatedBlock = block.number;
    }

    function borrow(address _user, uint256 amount) external {
        Position storage position = positions[_user];
        uint256 collValue = (position.collateralBalance * mockPrice) / 1e18;
        require(position.debt + amount <= collValue / 2, "Exceeds 50% LTV");
        position.debt += amount;
        LiqLayer(liqLayer).borrowLiq(amount, address(this));
        USDC.transfer(msg.sender, amount);
        position.lastUpdatedBlock = block.number;
    }

    function repay(address _user, uint256 amount) external {
        USDC.transferFrom(msg.sender, address(this), amount);

        USDC.approve(address(liqLayer), amount);
        LiqLayer(liqLayer).repayLiq(amount);
        Position storage position = positions[_user];
        position.debt -= amount;
        position.lastUpdatedBlock = block.number;
    }

    function withdrawCollateral(address _user, uint256 amount) external {
        Position storage position = positions[_user];
        position.collateralBalance -= amount;
        uint256 collValue = (position.collateralBalance * mockPrice) / 1e18;
        require(position.debt <= collValue / 2, "Would exceed 50% LTV");
        CONDITIONAL_TOKENS.safeTransferFrom(
            address(this),
            msg.sender,
            positionIdYes,
            amount,
            ""
        );
    }

    function liquidate(address _user) external {
        require(getLTV(_user) >= 77, "Not liquidatable");
        Position storage position = positions[_user];

        uint256 price = mockPrice;
        uint256 seizeAmount = (position.debt * 1e18) / price;
        require(
            seizeAmount <= position.collateralBalance,
            "Insufficient collateral"
        );

        CONDITIONAL_TOKENS.safeTransferFrom(
            msg.sender,
            address(this),
            positionIdNo,
            seizeAmount,
            ""
        );

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        CONDITIONAL_TOKENS.mergePositions(
            USDC,
            parentCollectionId,
            conditionId,
            partition,
            seizeAmount
        );

        position.collateralBalance -= seizeAmount;
        position.debt = 0;
        position.lastUpdatedBlock = block.number;

        uint256 priceNo = 1e6 - price;
        uint256 reimbursement = (seizeAmount * priceNo) / 1e18;
        USDC.transfer(msg.sender, reimbursement);
    }
}

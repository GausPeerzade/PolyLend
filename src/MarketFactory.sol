// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Market} from "./Market.sol";

contract MarketFactory is Ownable {
    address public immutable coreVault;
    address public immutable polymarketCTF;
    
    address[] public allMarkets;
    mapping(address => bool) public isMarket;
    
    event MarketCreated(
        address indexed market,
        uint256 indexed tokenId,
        uint256 interestRate,
        uint256 ltvRatio,
        uint256 liquidationThreshold,
        uint256 liquidationDiscount,
        address priceFeed
    );
    
    error InvalidParameter();
    
    constructor(address _coreVault, address _polymarketCTF) Ownable(msg.sender) {
        coreVault = _coreVault;
        polymarketCTF = _polymarketCTF;
    }
    
    function createMarket(
        address priceFeed,
        uint256 tokenId,
        uint256 interestRatePerYear,
        uint256 ltvRatio,
        uint256 liquidationThreshold,
        uint256 liquidationDiscount
    ) external onlyOwner returns (address market) {
        if (priceFeed == address(0)) revert InvalidParameter();
        if (interestRatePerYear == 0) revert InvalidParameter();
        if (ltvRatio == 0 || ltvRatio >= 10000) revert InvalidParameter();
        if (liquidationThreshold <= ltvRatio || liquidationThreshold >= 10000) 
            revert InvalidParameter();
        if (liquidationDiscount >= 10000) revert InvalidParameter();
        
        market = address(
            new Market(
                coreVault,
                polymarketCTF,
                priceFeed,
                tokenId,
                interestRatePerYear,
                ltvRatio,
                liquidationThreshold,
                liquidationDiscount
            )
        );
        
        allMarkets.push(market);
        isMarket[market] = true;
        
        emit MarketCreated(
            market,
            tokenId,
            interestRatePerYear,
            ltvRatio,
            liquidationThreshold,
            liquidationDiscount,
            priceFeed
        );
    }
    
    function getMarketCount() external view returns (uint256) {
        return allMarkets.length;
    }
    
    function getMarket(uint256 index) external view returns (address) {
        return allMarkets[index];
    }
    
    function getAllMarkets() external view returns (address[] memory) {
        return allMarkets;
    }
}

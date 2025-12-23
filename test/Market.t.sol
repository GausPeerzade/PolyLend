// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Market} from "../src/Market.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {CoreVault} from "../src/Core/CoreVault.sol";
import {MockPolymarketCTF} from "./mocks/MockPolymarketCTF.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract MarketTest is Test {
    Market public market;
    MarketFactory public factory;
    CoreVault public vault;
    MockPolymarketCTF public polymarket;
    MockChainlinkOracle public oracle;
    MockUSDC public usdc;

    address public owner = address(1);
    address public alice = address(2);
    address public bob = address(3);
    address public liquidator = address(4);

    uint256 public constant TOKEN_ID = 1;
    uint256 public constant INTEREST_RATE = 500;
    uint256 public constant LTV_RATIO = 5000;
    uint256 public constant LIQUIDATION_THRESHOLD = 7500;
    uint256 public constant LIQUIDATION_DISCOUNT = 1000;
    int256 public constant INITIAL_PRICE = 100000000;

    function setUp() public {
        vm.startPrank(owner);

        usdc = new MockUSDC();
        polymarket = new MockPolymarketCTF();
        oracle = new MockChainlinkOracle(INITIAL_PRICE, 8);

        vault = new CoreVault(address(usdc), "Vault Share", "vUSDC");

        factory = new MarketFactory(address(vault), address(polymarket));

        address marketAddress = factory.createMarket(
            address(oracle),
            TOKEN_ID,
            INTEREST_RATE,
            LTV_RATIO,
            LIQUIDATION_THRESHOLD,
            LIQUIDATION_DISCOUNT
        );

        market = Market(marketAddress);

        vault.changeMarketStatus(address(market), true);

        usdc.mint(address(vault), 1000000e6);

        vm.stopPrank();

        polymarket.mint(alice, TOKEN_ID, 1000 ether);
        polymarket.mint(bob, TOKEN_ID, 1000 ether);

        usdc.mint(alice, 10000e6);
        usdc.mint(bob, 10000e6);
        usdc.mint(liquidator, 10000e6);
    }

    function testDepositCollateral() public {
        vm.startPrank(alice);

        uint256 depositAmount = 100 ether;
        polymarket.setApprovalForAll(address(market), true);

        market.deposit(depositAmount);

        (uint256 collateral, , ) = market.getPosition(alice);
        assertEq(collateral, depositAmount);
        assertEq(polymarket.balanceOf(alice, TOKEN_ID), 900 ether);
        assertEq(polymarket.balanceOf(address(market), TOKEN_ID), depositAmount);

        vm.stopPrank();
    }

    function testWithdrawCollateral() public {
        vm.startPrank(alice);

        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);

        market.withdraw(50 ether);

        (uint256 collateral, , ) = market.getPosition(alice);
        assertEq(collateral, 50 ether);
        assertEq(polymarket.balanceOf(alice, TOKEN_ID), 950 ether);

        vm.stopPrank();
    }

    function testCannotWithdrawBeyondCollateral() public {
        vm.startPrank(alice);

        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);

        vm.expectRevert();
        market.withdraw(101 ether);

        vm.stopPrank();
    }

    function testBorrowAgainstCollateral() public {
        vm.startPrank(alice);

        uint256 depositAmount = 100 ether;
        polymarket.setApprovalForAll(address(market), true);
        market.deposit(depositAmount);

        uint256 borrowAmount = 50e6;
        uint256 balanceBefore = usdc.balanceOf(alice);
        market.borrow(borrowAmount);

        assertEq(usdc.balanceOf(alice), balanceBefore + borrowAmount);
        (, uint256 debt, ) = market.getPosition(alice);
        assertEq(debt, borrowAmount);

        vm.stopPrank();
    }

    function testCannotBorrowBeyondLTV() public {
        vm.startPrank(alice);

        uint256 depositAmount = 100 ether;
        polymarket.setApprovalForAll(address(market), true);
        market.deposit(depositAmount);

        uint256 maxBorrow = (100e6 * LTV_RATIO) / 10000;
        
        vm.expectRevert();
        market.borrow(maxBorrow + 1);

        vm.stopPrank();
    }

    function testRepayDebt() public {
        vm.startPrank(alice);

        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);

        uint256 borrowAmount = 40e6;
        market.borrow(borrowAmount);

        usdc.approve(address(market), borrowAmount);
        market.repay(borrowAmount);

        (, uint256 debt, ) = market.getPosition(alice);
        assertEq(debt, 0);

        vm.stopPrank();
    }

    function testInterestAccrual() public {
        vm.startPrank(alice);

        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);

        uint256 borrowAmount = 40e6;
        market.borrow(borrowAmount);

        vm.warp(block.timestamp + 365 days);
        oracle.updatePrice(INITIAL_PRICE);

        (, uint256 debt, ) = market.getPosition(alice);
        
        uint256 expectedInterest = (borrowAmount * INTEREST_RATE) / 10000;
        assertApproxEqAbs(debt, borrowAmount + expectedInterest, 1e6);

        vm.stopPrank();
    }

    function testLiquidationWhenUndercollateralized() public {
        vm.startPrank(alice);

        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);

        uint256 borrowAmount = 49e6;
        market.borrow(borrowAmount);

        vm.stopPrank();

        oracle.updatePrice(65000000);

        vm.startPrank(liquidator);

        (uint256 collateralBefore, uint256 debtBefore, ) = market.getPosition(alice);
        uint256 collateralValue = (collateralBefore * 65000000) / 1e20;
        uint256 maxAllowedDebt = (collateralValue * LIQUIDATION_THRESHOLD) / 10000;
        assertTrue(debtBefore > maxAllowedDebt);

        usdc.approve(address(market), borrowAmount);
        market.liquidate(alice, borrowAmount);

        (, uint256 debtAfter, ) = market.getPosition(alice);
        assertEq(debtAfter, 0);

        assertTrue(polymarket.balanceOf(liquidator, TOKEN_ID) > 0);

        vm.stopPrank();
    }

    function testCannotLiquidateHealthyPosition() public {
        vm.startPrank(alice);

        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);
        market.borrow(30e6);

        vm.stopPrank();

        vm.startPrank(liquidator);

        usdc.approve(address(market), 30e6);
        vm.expectRevert();
        market.liquidate(alice, 30e6);

        vm.stopPrank();
    }

    function testPriceUpdate() public {
        uint256 priceBefore = market.getLatestPrice();
        assertEq(priceBefore, uint256(INITIAL_PRICE));

        oracle.updatePrice(150000000);

        uint256 priceAfter = market.getLatestPrice();
        assertEq(priceAfter, 150000000);
    }

    function testHealthFactor() public {
        vm.startPrank(alice);

        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);

        (, , uint256 healthBefore) = market.getPosition(alice);
        assertEq(healthBefore, type(uint256).max);

        market.borrow(40e6);

        (, , uint256 healthAfter) = market.getPosition(alice);
        assertTrue(healthAfter > LTV_RATIO);
        assertTrue(healthAfter < type(uint256).max);

        vm.stopPrank();
    }

    function testMultipleUsers() public {
        vm.startPrank(alice);
        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);
        market.borrow(30e6);
        vm.stopPrank();

        vm.startPrank(bob);
        polymarket.setApprovalForAll(address(market), true);
        market.deposit(200 ether);
        market.borrow(60e6);
        vm.stopPrank();

        (, uint256 aliceDebt, ) = market.getPosition(alice);
        (, uint256 bobDebt, ) = market.getPosition(bob);

        assertEq(aliceDebt, 30e6);
        assertEq(bobDebt, 60e6);
    }

    function testCannotWithdrawWithActiveDebt() public {
        vm.startPrank(alice);

        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);
        market.borrow(40e6);

        vm.expectRevert();
        market.withdraw(60 ether);

        vm.stopPrank();
    }

    function testPartialRepayment() public {
        vm.startPrank(alice);

        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);
        market.borrow(40e6);

        usdc.approve(address(market), 20e6);
        market.repay(20e6);

        (, uint256 debt, ) = market.getPosition(alice);
        assertEq(debt, 20e6);

        vm.stopPrank();
    }

    function testLiquidationDiscount() public {
        vm.startPrank(alice);
        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);
        market.borrow(49e6);
        vm.stopPrank();

        oracle.updatePrice(65000000);

        vm.startPrank(liquidator);
        uint256 liquidatorBalanceBefore = polymarket.balanceOf(liquidator, TOKEN_ID);

        usdc.approve(address(market), 49e6);
        market.liquidate(alice, 49e6);

        uint256 liquidatorBalanceAfter = polymarket.balanceOf(liquidator, TOKEN_ID);
        uint256 collateralReceived = liquidatorBalanceAfter - liquidatorBalanceBefore;

        uint256 debtRepaid = 49e6;
        uint256 price = 65000000;
        uint256 collateralValue = (debtRepaid * 1e20) / price;
        uint256 expectedWithDiscount = (collateralValue * (10000 + LIQUIDATION_DISCOUNT)) / 10000;

        assertApproxEqAbs(collateralReceived, expectedWithDiscount, 1 ether);

        vm.stopPrank();
    }

    function testVaultIntegration() public {
        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));
        uint256 totalBorrowedBefore = vault.totalBorrowed();

        vm.startPrank(alice);
        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);
        market.borrow(40e6);
        vm.stopPrank();

        assertEq(vault.totalBorrowed(), totalBorrowedBefore + 40e6);

        vm.startPrank(alice);
        usdc.approve(address(market), 40e6);
        market.repay(40e6);
        vm.stopPrank();

        assertEq(vault.totalBorrowed(), totalBorrowedBefore);
        assertGe(usdc.balanceOf(address(vault)), vaultBalanceBefore);
    }

    function testCannotBorrowWithoutCollateral() public {
        vm.startPrank(alice);

        vm.expectRevert();
        market.borrow(10e6);

        vm.stopPrank();
    }

    function testCannotDepositZero() public {
        vm.startPrank(alice);

        polymarket.setApprovalForAll(address(market), true);
        vm.expectRevert();
        market.deposit(0);

        vm.stopPrank();
    }

    function testGetPosition() public {
        vm.startPrank(alice);

        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);
        market.borrow(40e6);

        (uint256 collateral, uint256 debt, uint256 healthFactor) = market.getPosition(alice);

        assertEq(collateral, 100 ether);
        assertEq(debt, 40e6);
        assertTrue(healthFactor > 0);
        assertTrue(healthFactor < type(uint256).max);

        vm.stopPrank();
    }

    function testCannotSelfLiquidate() public {
        vm.startPrank(alice);

        polymarket.setApprovalForAll(address(market), true);
        market.deposit(100 ether);
        market.borrow(49e6);

        vm.stopPrank();

        oracle.updatePrice(65000000);

        vm.startPrank(alice);
        usdc.approve(address(market), 49e6);
        vm.expectRevert();
        market.liquidate(alice, 49e6);
        vm.stopPrank();
    }

    function testMarketNotEnabledInVault() public {
        vm.startPrank(owner);

        address newMarketAddress = factory.createMarket(
            address(oracle),
            2,
            INTEREST_RATE,
            LTV_RATIO,
            LIQUIDATION_THRESHOLD,
            LIQUIDATION_DISCOUNT
        );

        Market newMarket = Market(newMarketAddress);

        vm.stopPrank();

        polymarket.mint(alice, 2, 100 ether);

        vm.startPrank(alice);
        polymarket.setApprovalForAll(address(newMarket), true);
        newMarket.deposit(100 ether);

        vm.expectRevert();
        newMarket.borrow(40e6);

        vm.stopPrank();
    }
}

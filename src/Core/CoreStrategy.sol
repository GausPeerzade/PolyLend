// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoreVault} from "./CoreVault.sol";

interface IStrategy {
    function deposit() external;
    function withdraw() external;
    function balance() external view returns (uint256);
}

contract CoreStrategy is CoreVault {
    address public strategy;
    bool public onStrat;

    constructor(address _depositToken, string memory name, string memory symbol, address _strategy)
        CoreVault(_depositToken, name, symbol)
    {
        strategy = _strategy;
        onStrat = true;
    }

    function deposit() public {
        onStrat = true;
        IStrategy(strategy).deposit();
    }

    function withdraw() public {
        onStrat = false;
        IStrategy(strategy).withdraw();
    }

    function totalAssets() public view override returns (uint256) {
        uint256 stratBalance = IStrategy(strategy).balance();
        return IERC20(asset()).balanceOf(address(this)) + totalBorrowed + stratBalance;
    }
}

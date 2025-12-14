// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract LiqLayer is ERC4626, Ownable {
    uint256 public totalBorrowed;

    mapping(address => bool) public markets;

    //Errors
    error MarketNotAllowed(address market);
    error InsufficientBalance(uint256 balance, uint256 needed);

    constructor(
        address _depositToken,
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) ERC4626(IERC20(_depositToken)) Ownable(msg.sender) {}

    function changeMarketStatus(
        address _market,
        bool _status
    ) public onlyOwner {
        markets[_market] = _status;
    }

    function borrowLiq(uint256 _amount, address _receiver) public {
        if (!markets[msg.sender]) revert MarketNotAllowed(msg.sender);

        if (IERC20(asset()).balanceOf(address(this)) < _amount) {
            revert InsufficientBalance(
                IERC20(asset()).balanceOf(address(this)),
                _amount
            );
        }

        IERC20(asset()).transfer(_receiver, _amount);
        totalBorrowed += _amount;
    }

    function repayLiq(uint256 _amount) public {
        if (!markets[msg.sender]) revert MarketNotAllowed(msg.sender);
        IERC20(asset()).transferFrom(msg.sender, address(this), _amount);
        totalBorrowed -= _amount;
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalBorrowed;
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface ICoreVault {
    function borrowLiq(uint256 _amount, address _receiver) external;
    function repayLiq(uint256 _amount) external;
    function badDebt(uint256 _actualDebt, uint256 _repayment) external;
    function asset() external view returns (address);
    function changeMarketStatus(address _market, bool _status) external;
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.16;

interface IDepositLimitModule {
    function availableDepositLimit(address receiver) external view returns (uint256);
}
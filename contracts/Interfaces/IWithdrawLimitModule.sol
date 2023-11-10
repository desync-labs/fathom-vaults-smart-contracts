// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.16;

interface IWithdrawLimitModule {
    function availableWithdrawLimit(address owner, uint256 maxLoss, address[] calldata strategies) external returns (uint256);
}
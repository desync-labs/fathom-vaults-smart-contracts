// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.16;

interface IAccountant {
    function report(address strategy, uint256 gain, uint256 loss) external returns (uint256, uint256);
}
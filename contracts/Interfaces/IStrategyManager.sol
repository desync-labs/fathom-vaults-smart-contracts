// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.16;

interface IStrategyManager {
    function addStrategy(address newStrategy) external;
    function revokeStrategy(address strategy, bool force) external;
}
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.16;

interface IStrategyManager {
    function addStrategy(address newStrategy) external;
    function revokeStrategy(address strategy, bool force) external;
    function updateMaxDebtForStrategy(address strategy, uint256 newMaxDebt) external;
    function updateDebt(address strategy, uint256 targetDebt, address sharesManager) external returns (uint256);
}
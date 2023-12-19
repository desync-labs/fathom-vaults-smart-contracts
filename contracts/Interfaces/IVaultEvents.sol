// SPDX-License-Identifier: AGPL 3.0
// Copyright Fathom 2023

pragma solidity ^0.8.16;

import "../VaultStructs.sol";

interface IVaultEvents {
    // STRATEGY EVENTS
    event StrategyChanged(address indexed strategy, StrategyChangeType changeType);
    event StrategyReported(
        address indexed strategy,
        uint256 gain,
        uint256 loss,
        uint256 currentDebt,
        uint256 protocolFees,
        uint256 totalFees,
        uint256 totalRefunds
    );
    // DEBT MANAGEMENT EVENTS
    event DebtUpdated(
        address indexed strategy,
        uint256 currentDebt,
        uint256 newDebt
    );
    // ROLE UPDATES
    event RoleSet(address indexed account, bytes32 role);
    event RoleStatusChanged(bytes32 indexed role, RoleStatusChange indexed status);
    event UpdateRoleManager(address indexed roleManager);

    event UpdateAccountant(address indexed accountant);
    event UpdateDefaultQueue(address[] newDefaultQueue);
    event UpdateUseDefaultQueue(bool useDefaultQueue);
    event UpdatedMaxDebtForStrategy(
        address indexed sender,
        address indexed strategy,
        uint256 newDebt
    );
    event UpdateDepositLimit(uint256 depositLimit);
    event UpdateMinimumTotalIdle(uint256 minimumTotalIdle);
    event UpdateProfitMaxUnlockTime(uint256 profitMaxUnlockTime);
    event DebtPurchased(address indexed strategy, uint256 amount);
    event Shutdown();

    // STORAGE MANAGEMENT EVENTS
    event UpdateDepositLimitModule(address indexed depositLimitModule);
    event UpdateWithdrawLimitModule(address indexed withdrawLimitModule);

    // FEE EVENTS
    event UpdatedFees(
        uint256 indexed totalFees,
        uint256 indexed totalRefunds,
        uint256 indexed protocolFees,
        address protocolFeeRecipient
    );
}
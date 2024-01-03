// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

import "../VaultStructs.sol";

interface IVaultEvents {
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
    event DebtUpdated(address indexed strategy, uint256 currentDebt, uint256 newDebt);
    event RoleSet(address indexed account, bytes32 role);
    event RoleStatusChanged(bytes32 indexed role, RoleStatusChange status);
    event UpdatedRoleManager(address roleManager);

    event UpdatedAccountant(address accountant);
    event UpdatedFees(uint256 totalFees, uint256 totalRefunds, uint256 protocolFees, address protocolFeeRecipient);
    event UpdatedDefaultQueue(address[] newDefaultQueue);
    event UpdatedUseDefaultQueue(bool useDefaultQueue);
    event UpdatedMaxDebtForStrategy(address indexed sender, address indexed strategy, uint256 newDebt);
    event UpdatedDepositLimit(uint256 depositLimit);
    event UpdatedMinimumTotalIdle(uint256 minimumTotalIdle);
    event UpdatedProfitMaxUnlockTime(uint256 profitMaxUnlockTime);
    event DebtPurchased(address indexed strategy, uint256 amount);
    event Shutdown();

    event UpdatedDepositLimitModule(address depositLimitModule);
    event UpdatedWithdrawLimitModule(address withdrawLimitModule);
}

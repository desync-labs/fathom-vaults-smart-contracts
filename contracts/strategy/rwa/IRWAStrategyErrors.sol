// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

interface IRWAStrategyErrors {
    /// @notice Error when the caller is not the RWA manager
    error NotRWAManager();

    /// @notice Error when the manager address is zero
    error ZeroManager();

    /// @notice Error when the deposit limit is zero or less than already deposited amount
    error InvalidDepositLimit();

    /// @notice Error when the minimum deploy amount is greater than the total supply of the asset
    error InvalidMinDeployAmount();

    /// @notice Error when the loss amount is greater than the total invested amount
    error InvalidLossAmount();

    /// @notice Error when the manager balance is too low
    error ManagerBalanceTooLow();
}
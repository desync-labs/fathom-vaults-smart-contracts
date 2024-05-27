// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

interface ITradeFintechStrategyErrors {
    /// @notice Error when the deposit limit is zero or less than already deposited amount
    error InvalidDepositLimit(uint256 depositLimit, uint256 totalInvestedAmount);

    /// @notice Error when the loss amount is greater than the total invested amount
    error InvalidLossAmount(uint256 lossAmount, uint256 totalInvestedAmount);

    /// @notice Error when the manager balance is too low
    error ManagerBalanceTooLow(uint256 requiredAmount, uint256 managerBalance, uint256 totalInvestedAmount);


    error InvalidPeriods();

    error InsufficientFunds();

    error ZeroValue();
}
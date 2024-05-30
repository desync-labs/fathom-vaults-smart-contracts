// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

interface ITradeFintechStrategyErrors {
    /// @notice Error when the deposit limit is zero or less than already deposited amount
    error InvalidDepositLimit(uint256 depositLimit, uint256 totalInvestedAmount);

    /// @notice Error when the loss amount is greater than the total invested amount
    error InvalidLossAmount(uint256 lossAmount, uint256 totalInvestedAmount);

    /// @notice Error when the manager balance is too low
    error ManagerBalanceTooLow(uint256 requiredAmount, uint256 managerBalance);

    /// @notice depositPeriodEnds or lockPeriodEnds are less than the current block timestamp
    error InvalidPeriods();

    /// @notice Error trying to lock more funds than currently available in the strategy
    error InsufficientFundsIdle(uint256 requiredAmount, uint256 availableAmount);

    /// @notice Error trying to unlock more funds than are locked
    error InsufficientFundsLocked(uint256 requiredAmount, uint256 availableAmount);

    /// @notice Error when trying to lock funds after the lock period has ended
    error LockPeriodEnded();

    /// @notice Error when the amount is zero
    error ZeroAmount();
}
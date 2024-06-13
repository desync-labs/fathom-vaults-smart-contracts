// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

interface IRWAStrategyEvents {
    /// @notice Emits when a loss is reported
    /// @param loss The amount of the loss
    event LossReported(address indexed sender, uint256 loss);

    /// @notice Emits when a gain is reported
    /// @param gain The amount of the gain
    event GainReported(address indexed sender, uint256 gain);

    /// @notice Emits when the deposit limit is set
    /// @param depositLimit The new deposit limit
    event DepositLimitSet(address indexed sender, uint256 depositLimit);

    /// @notice Emits when the minimum deploy amount is set
    /// @param minDeployAmount The new minimum deploy amount
    event MinDeployAmountSet(address indexed sender, uint256 minDeployAmount);
}
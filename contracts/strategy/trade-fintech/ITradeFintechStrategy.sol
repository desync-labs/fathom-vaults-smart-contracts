// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

import {ITradeFintechStrategyEvents} from "./ITradeFintechStrategyEvents.sol";
import {ITradeFintechStrategyErrors} from "./ITradeFintechStrategyErrors.sol";

interface ITradeFintechStrategy is ITradeFintechStrategyEvents, ITradeFintechStrategyErrors {
    /// @notice Report a gain or loss
    /// gain will transfer the gain to the strategy
    /// lose will reduce the total invested amount
    /// @param amount The amount of the loss
    function reportGainOrLoss(uint256 amount, bool isGain) external;

    /// @notice Set the deposit limit
    /// @dev Only the strategy manager can call this
    /// @param limit The new deposit limit
    function setDepositLimit(uint256 limit) external;

    /// @notice Transfer funds from the strategy to the manager
    /// @dev Only the strategy manager can call this
    /// @param amount The amount to transfer
    function lockFunds(uint256 amount) external;

    /// @notice Return funds to the strategy
    /// @dev Only the strategy manager can call this
    /// @param amount The amount to return
    function returnFunds(uint256 amount) external;

    /// @notice get the deposit limit
    /// @return The deposit limit
    function depositLimit() external view returns (uint256);

    /// @notice get the total invested amount
    /// @return The total invested amount
    function totalInvested() external view returns (uint256);
}
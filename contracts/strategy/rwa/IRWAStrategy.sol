// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

import {IRWAStrategyEvents} from "./IRWAStrategyEvents.sol";
import {IRWAStrategyErrors} from "./IRWAStrategyErrors.sol";

interface IRWAStrategy is IRWAStrategyEvents, IRWAStrategyErrors {
    /// @notice Report a gain or loss
    /// @dev Only the rwa manager can call this
    /// gain will transfer the gain to the strategy
    /// lose will reduce the total invested amount
    /// @param _amount The amount of the loss
    function reportGainOrLoss(uint256 _amount, bool isGain) external;

    /// @notice Set the deposit limit
    /// @dev Only the strategy manager can call this
    /// @param _depositLimit The new deposit limit
    function setDepositLimit(uint256 _depositLimit) external;

    /// @notice Set the minimum amount to deploy
    /// @dev Only the strategy manager can call this
    /// @param _minDeployAmount The new minimum deploy amount
    function setMinDeployAmount(uint256 _minDeployAmount) external;

    /// @notice get the minimum amount to deploy
    /// @return The minimum amount to deploy
    function minDeployAmount() external view returns (uint256);

    /// @notice get the deposit limit
    /// @return The deposit limit
    function depositLimit() external view returns (uint256);

    /// @notice get the total invested amount
    /// @return The total invested amount
    function totalInvested() external view returns (uint256);

    /// @notice get the manager address
    /// @return The manager address
    function managerAddress() external view returns (address);
}
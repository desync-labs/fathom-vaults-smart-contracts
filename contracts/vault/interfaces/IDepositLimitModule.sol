// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

interface IDepositLimitModule {
    /// @notice Get deposit limit for a user
    /// @param receiver User address
    /// @return Deposit limit
    function availableDepositLimit(address receiver) external view returns (uint256);
}

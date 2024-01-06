// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

interface IDepositLimitModule {
    function availableDepositLimit(address receiver) external view returns (uint256);
}

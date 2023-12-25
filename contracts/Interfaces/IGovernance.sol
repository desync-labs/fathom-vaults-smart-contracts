// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

interface IGovernance {
    function buyDebt(address strategy, uint256 amount) external;

    function shutdownVault() external;
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

import "./interfaces/IAccountant.sol";

/// @title GenericAccountant
/// @dev GenericAccountant is a simple accountant that charges a 1% management fee.
/// @dev GenericAccountant isn't giving any refunds in case of losses.
contract GenericAccountant is IAccountant {
    /// @notice Constant defining the management fee;
    uint256 internal constant MANAGEMENT_FEE = 100;
    /// @notice Constant defining the fee basis points.
    uint256 internal constant FEE_BPS = 10000;

    function report(address /*strategy*/, uint256 gain, uint256 /*loss*/) external pure override returns (uint256, uint256) {
        return ((gain * MANAGEMENT_FEE) / FEE_BPS, 0);
    }
}

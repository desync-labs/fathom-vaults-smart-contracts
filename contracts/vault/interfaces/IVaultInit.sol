// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

interface IVaultInit {
    function initialize(
        uint256 _profitMaxUnlockTime,
        uint256 _assetType,
        address _asset,
        string calldata _name,
        string calldata _symbol,
        address _accountant,
        address _admin
    ) external;
}

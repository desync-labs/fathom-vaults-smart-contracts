// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

interface IFactoryEvents {
    event VaultPackageUpdated(uint256 id, address indexed vaultPackage);
    event VaultPackageAdded(address indexed vaultPackage, address indexed creator);
    event FeeConfigUpdated(address indexed feeRecipient, uint16 feeBPS);
    event VaultDeployed(
        address indexed vault,
        uint32 profitMaxUnlockTime,
        address indexed asset,
        string name,
        string symbol,
        address indexed accountant,
        address admin
    );
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

interface IFactory {
    function updateFeeConfig(address _feeRecipient, uint16 _feeBPS) external;

    function deployVault(
        address _vaultPackageAddress,
        uint32 _profitMaxUnlockTime,
        uint256 _assetType,
        address _asset,
        string calldata _name,
        string calldata _symbol,
        address _accountant,
        address _admin
    ) external returns (address);

    function addVaultPackage(address _vaultPackage) external;

    function removeVaultPackage(address _vaultPackage) external;

    function getVaults() external view returns (address[] memory);

    function isVaultPackage(address _vaultPackage) external view returns (bool);

    function protocolFeeConfig() external view returns (uint16 /*feeBps*/, address /*feeRecipient*/);
}

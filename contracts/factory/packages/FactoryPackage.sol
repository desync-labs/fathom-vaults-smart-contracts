// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

import "../interfaces/IFactory.sol";
import "../interfaces/IFactoryInit.sol";
import "../interfaces/IFactoryEvents.sol";
import "../FactoryStorage.sol";
import "../FactoryErrors.sol";
import "../../vault/interfaces/IVaultInit.sol";
import "../../vault/FathomVault.sol";

contract FactoryPackage is FactoryStorage, IFactory, IFactoryInit, IFactoryEvents {
    function initialize(address _vaultPackage, address _feeRecipient, uint16 _feeBPS) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (initialized == true) {
            revert AlreadyInitialized();
        }
        if (_vaultPackage == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        if (_feeBPS > MAX_BPS) {
            revert FeeGreaterThan100();
        }

        feeRecipient = _feeRecipient;
        feeBPS = _feeBPS;

        emit FeeConfigUpdated(_feeRecipient, _feeBPS);

        initialized = true;
    }

    function addVaultPackage(address _vaultPackage) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_vaultPackage == address(0)) {
            revert ZeroAddress();
        }
        for (uint256 i = 0; i < vaultPackages.length; i++) {
            if (vaultPackages[i] == _vaultPackage) {
                revert SameVaultPackage();
            }
        }
        vaultPackages.push(_vaultPackage);
        uint256 id = vaultPackages.length - 1;
        emit VaultPackageAdded(id, _vaultPackage);
    }

    function updateFeeConfig(address _feeRecipient, uint16 _feeBPS) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        if (_feeBPS > MAX_BPS) {
            revert FeeGreaterThan100();
        }
        feeRecipient = _feeRecipient;
        feeBPS = _feeBPS;
        emit FeeConfigUpdated(_feeRecipient, _feeBPS);
    }

    function deployVault(
        uint256 _vaultPackageId,
        uint32 _profitMaxUnlockTime,
        uint256 _assetType,
        address _asset,
        string calldata _name,
        string calldata _symbol,
        address _accountant,
        address _admin
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) returns (address) {
        if (vaultPackages[_vaultPackageId] == address(0)) {
            revert InvalidVaultPackageId();
        }
        FathomVault vault = new FathomVault(vaultPackages[_vaultPackageId], new bytes(0));
        IVaultInit(address(vault)).initialize(_profitMaxUnlockTime, _assetType, _asset, _name, _symbol, _accountant, _admin);

        vaults.push(address(vault));
        vaultCreators[address(vault)] = msg.sender;
        emit VaultDeployed(address(vault), _profitMaxUnlockTime, _asset, _name, _symbol, _accountant, _admin);
        return address(vault);
    }

    function getVaults() external view override returns (address[] memory) {
        return vaults;
    }

    function getVaultPackages() external view override returns (address[] memory) {
        return vaultPackages;
    }

    /**
     * @notice Retrieves a single vault package by its index.
     * @param index The index of the vault package in the array.
     * @return The address of the vault package at the specified index.
     */
    function getVaultPackage(uint256 index) external view override returns (address) {
        if (index > vaultPackages.length) {
            revert InvalidVaultPackageId();
        }
        return vaultPackages[index];
    }

    function getVaultCreator(address _vault) external view override returns (address) {
        return vaultCreators[_vault];
    }

    function protocolFeeConfig() external view override returns (uint16 /*feeBps*/, address /*feeRecipient*/) {
        return (feeBPS, feeRecipient);
    }
}

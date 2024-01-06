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

// solhint-disable custom-errors
contract FactoryPackage is FactoryStorage, IFactory, IFactoryInit, IFactoryEvents {
    function initialize(address _vaultPackage, address _feeRecipient, uint16 _feeBPS) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (initialized == true) {
            revert AlreadyInitialized();
        }

        require(_vaultPackage != address(0), "Factory: vaultPackage cannot be 0");
        vaultPackage = _vaultPackage;
        require(_feeRecipient != address(0), "Factory: feeRecipient cannot be 0");
        feeRecipient = _feeRecipient;
        require(_feeBPS <= MAX_BPS, "Factory: feeBPS too high");
        feeBPS = _feeBPS;

        emit FeeConfigUpdated(_feeRecipient, _feeBPS);

        initialized = true;
    }

    // solhint-disable-next-line comprehensive-interface
    function updateVaultPackage(address _vaultPackage) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_vaultPackage != address(0), "Factory: vaultPackage cannot be 0");
        vaultPackage = _vaultPackage;
        emit VaultPackageUpdated(_vaultPackage);
    }

    // solhint-disable-next-line comprehensive-interface
    function updateFeeConfig(address _feeRecipient, uint16 _feeBPS) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeRecipient != address(0), "Factory: feeRecipient cannot be 0");
        feeRecipient = _feeRecipient;
        require(_feeBPS <= MAX_BPS, "Factory: feeBPS too high");
        feeBPS = _feeBPS;
        emit FeeConfigUpdated(_feeRecipient, _feeBPS);
    }

    // solhint-disable-next-line comprehensive-interface
    function deployVault(
        uint32 _profitMaxUnlockTime,
        address _asset,
        string calldata _name,
        string calldata _symbol,
        address _accountant,
        address _admin
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address) {
        FathomVault vault = new FathomVault(vaultPackage, new bytes(0));
        IVaultInit(address(vault)).initialize(_profitMaxUnlockTime, _asset, _name, _symbol, _accountant, _admin);

        vaults.push(address(vault));
        vaultCreators[address(vault)] = msg.sender;
        emit VaultDeployed(address(vault), _profitMaxUnlockTime, _asset, _name, _symbol, _accountant, _admin);
        return address(vault);
    }

    // solhint-disable-next-line comprehensive-interface
    function getVaults() external view returns (address[] memory) {
        return vaults;
    }

    // solhint-disable-next-line comprehensive-interface
    function getVaultCreator(address _vault) external view returns (address) {
        return vaultCreators[_vault];
    }

    function protocolFeeConfig() external view override returns (uint16 /*feeBps*/, address /*feeRecipient*/) {
        return (feeBPS, feeRecipient);
    }
}

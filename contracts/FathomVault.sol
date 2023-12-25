// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.19;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./VaultStorage.sol";
import "./interfaces/IVaultEvents.sol";
import "@openzeppelin/contracts/proxy/Proxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Upgrade.sol";

interface IVaultUpgradeable {
    function setImplementation(address implementation, bytes memory _data) external;
}

/**
@title Yearn V3 Vault
@notice The Yearn VaultV3 is designed as a non-opinionated system to distribute funds of 
depositors for a specific `asset` into different opportunities (aka Strategies)
and manage accounting in a robust way.
*/

// Solidity version of the Vyper contract
contract FathomVault is Proxy, ERC1967Upgrade, AccessControl, IVaultUpgradeable, ReentrancyGuard, VaultStorage, IVaultEvents {
    /**
     * @dev Initializes the upgradeable proxy with an initial implementation specified by `implementation`.
     *
     * If `_data` is nonempty, it's used as data in a delegate call to `implementation`. This will typically be an
     * encoded function call, and allows initializing the storage of the proxy like a Solidity constructor.
     *
     * Requirements:
     *
     * - If `data` is empty, `msg.value` must be zero.
     */
    constructor(address implementation, bytes memory _data) payable {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _upgradeToAndCall(implementation, _data, false);
    }

    function setImplementation(address implementation, bytes memory _data) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _upgradeToAndCall(implementation, _data, false);
    }

    /**
     * @dev Returns the current implementation address.
     *
     * TIP: To get this value clients can read directly from the storage slot shown below (specified by EIP1967) using
     * the https://eth.wiki/json-rpc/API#eth_getstorageat[`eth_getStorageAt`] RPC call.
     * `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`
     */
    function _implementation() internal view virtual override returns (address impl) {
        return ERC1967Upgrade._getImplementation();
    }
}

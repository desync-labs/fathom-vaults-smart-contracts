// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.19;

import "../VaultStorage.sol";
import "../Interfaces/IVaultEvents.sol";
import "./Interfaces/IGovernancePackage.sol";
import "../Interfaces/IStrategy.sol";
import "../Interfaces/ISharesManager.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
@title GOVERNANCE MANAGEMENT
*/

contract GovernancePackage is AccessControl, VaultStorage, IVaultEvents, IGovernancePackage, ReentrancyGuard {
    // solhint-disable not-rely-on-time
    // solhint-disable var-name-mixedcase
    // solhint-disable function-max-lines
    // solhint-disable code-complexity
    // solhint-disable max-line-length

    error InactiveStrategy();
    error ZeroValue();
    error AlreadyInitialized();

    function initialize(address _sharesManager) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (initialized == true) {
            revert AlreadyInitialized();
        }
        sharesManager = _sharesManager;
        _grantRole(DEFAULT_ADMIN_ROLE, _sharesManager);

        initialized = true;
    }

    // @notice Used for governance to buy bad debt from the vault.
    // @dev This should only ever be used in an emergency in place
    //  of force revoking a strategy in order to not report a loss.
    //  It allows the DEBT_PURCHASER role to buy the strategies debt
    //  for an equal amount of `asset`.

    // @param strategy The strategy to buy the debt for
    // @param amount The amount of debt to buy from the vault.
    function buyDebt(address strategy, uint256 amount) external override onlyRole(DEBT_PURCHASER) nonReentrant {
        if (strategies[strategy].activation == 0) {
            revert InactiveStrategy();
        }

        // Cache the current debt.
        uint256 currentDebt = strategies[strategy].currentDebt;

        if (currentDebt <= 0 || amount <= 0) {
            revert ZeroValue();
        }

        if (amount > currentDebt) {
            amount = currentDebt;
        }

        // We get the proportion of the debt that is being bought and
        // transfer the equivalent shares. We assume this is being used
        // due to strategy issues so won't rely on its conversion rates.
        uint256 shares = (IERC20(strategy).balanceOf(address(this)) * amount) / currentDebt;

        if (shares <= 0) {
            revert ZeroValue();
        }

        ISharesManager(sharesManager).erc20SafeTransferFrom(sharesManager, msg.sender, address(this), amount);

        // Lower strategy debt
        strategies[strategy].currentDebt -= amount;
        // lower total debt
        totalDebtAmount -= amount;
        // Increase total idle
        totalIdleAmount += amount;

        // Log debt change
        emit DebtUpdated(strategy, currentDebt, currentDebt - amount);

        // Transfer the strategies shares out
        ISharesManager(sharesManager).erc20SafeTransfer(strategy, msg.sender, shares);

        // Log the debt purchase
        emit DebtPurchased(strategy, amount);
    }

    // EMERGENCY MANAGEMENT

    // @notice Shutdown the vault.
    function shutdownVault() external override onlyRole(EMERGENCY_MANAGER) {
        if (shutdown == true) {
            revert InactiveStrategy();
        }

        // Shutdown the vault.
        shutdown = true;

        // Set deposit limit to 0.
        if (depositLimitModule != address(0)) {
            depositLimitModule = address(0);
            emit UpdateDepositLimitModule(address(0));
        }

        depositLimit = 0;
        emit UpdateDepositLimit(0);

        _grantRole(DEBT_MANAGER, msg.sender);
        emit Shutdown();
    }
}

// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.19;

import "../VaultStorage.sol";
import "../CommonErrors.sol";
import "../interfaces/IVaultEvents.sol";
import "./interfaces/ISettersPackage.sol";
import "../interfaces/ISharesManager.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/**
@title SETTERS CONTRACT
*/

contract SettersPackage is AccessControl, VaultStorage, IVaultEvents, ISettersPackage {
    function initialize(address _sharesManager) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (initialized == true) {
            revert AlreadyInitialized();
        }
        sharesManager = _sharesManager;
        _grantRole(DEFAULT_ADMIN_ROLE, _sharesManager);

        initialized = true;
    }

    // @notice Set the new accountant address.
    // @param new_accountant The new accountant address.
    function setAccountant(address newAccountant) external override onlyRole(ACCOUNTANT_MANAGER) {
        accountant = newAccountant;
        emit UpdateAccountant(newAccountant);
    }

    // @notice Set the new default queue array.
    // @dev Will check each strategy to make sure it is active.
    // @param new_default_queue The new default queue array.
    function setDefaultQueue(address[] calldata newDefaultQueue) external override onlyRole(QUEUE_MANAGER) {
        // Make sure every strategy in the new queue is active.
        for (uint256 i = 0; i < newDefaultQueue.length; i++) {
            address strategy = newDefaultQueue[i];
            if (strategies[strategy].activation == 0) {
                revert InactiveStrategy(strategy);
            }
        }
        // Save the new queue.
        defaultQueue = newDefaultQueue;
        emit UpdateDefaultQueue(newDefaultQueue);
    }

    // @notice Set a new value for `use_default_queue`.
    // @dev If set `True` the default queue will always be
    //  used no matter whats passed in.
    // @param use_default_queue new value.
    function setUseDefaultQueue(bool _useDefaultQueue) external override onlyRole(QUEUE_MANAGER) {
        useDefaultQueue = _useDefaultQueue;
        emit UpdateUseDefaultQueue(_useDefaultQueue);
    }

    // @notice Set the new deposit limit.
    // @dev Can not be changed if a deposit_limit_module
    //  is set or if shutdown.
    // @param deposit_limit The new deposit limit.
    function setDepositLimit(uint256 _depositLimit) external override {
        if (shutdown == true) {
            revert StrategyIsShutdown();
        }
        if (depositLimitModule != address(0)) {
            revert UsingModule();
        }
        depositLimit = _depositLimit;
        emit UpdateDepositLimit(_depositLimit);
    }

    // @notice Set a contract to handle the deposit limit.
    // @dev The default `deposit_limit` will need to be set to
    //  max uint256 since the module will override it.
    // @param deposit_limit_module Address of the module.
    function setDepositLimitModule(address _depositLimitModule) external override onlyRole(DEPOSIT_LIMIT_MANAGER) {
        if (shutdown == true) {
            revert StrategyIsShutdown();
        }
        if (depositLimit != type(uint256).max) {
            revert UsingDepositLimit();
        }
        depositLimitModule = _depositLimitModule;
        emit UpdateDepositLimitModule(_depositLimitModule);
    }

    // @notice Set a contract to handle the withdraw limit.
    // @dev This will override the default `max_withdraw`.
    // @param withdraw_limit_module Address of the module.
    function setWithdrawLimitModule(address _withdrawLimitModule) external override onlyRole(WITHDRAW_LIMIT_MANAGER) {
        withdrawLimitModule = _withdrawLimitModule;
        emit UpdateWithdrawLimitModule(_withdrawLimitModule);
    }

    // @notice Set the new minimum total idle.
    // @param minimum_total_idle The new minimum total idle.
    function setMinimumTotalIdle(uint256 _minimumTotalIdle) external override onlyRole(MINIMUM_IDLE_MANAGER) {
        minimumTotalIdle = _minimumTotalIdle;
        emit UpdateMinimumTotalIdle(_minimumTotalIdle);
    }

    // @notice Set the new profit max unlock time.
    // @dev The time is denominated in seconds and must be less than 1 year.
    //  We only need to update locking period if setting to 0,
    //  since the current period will use the old rate and on the next
    //  report it will be reset with the new unlocking time.

    //  Setting to 0 will cause any currently locked profit to instantly
    //  unlock and an immediate increase in the vaults Price Per Share.

    // @param new_profit_max_unlock_time The new profit max unlock time.
    function setProfitMaxUnlockTime(uint256 _newProfitMaxUnlockTime) external override onlyRole(PROFIT_UNLOCK_MANAGER) {
        // Must be less than one year for report cycles
        if (_newProfitMaxUnlockTime > ONE_YEAR) {
            revert ProfitUnlockTimeTooLong();
        }

        // If setting to 0 we need to reset any locked values.
        if (_newProfitMaxUnlockTime == 0) {
            // Burn any shares the vault still has.
            ISharesManager(sharesManager).burnShares(_balanceOf[address(this)], address(this));
            // Reset unlocking variables to 0.
            profitUnlockingRate = 0;
            fullProfitUnlockDate = 0;
        }
        profitMaxUnlockTime = _newProfitMaxUnlockTime;
        emit UpdateProfitMaxUnlockTime(_newProfitMaxUnlockTime);
    }
}

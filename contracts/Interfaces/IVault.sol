// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.16;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IVault is IERC4626 {
    struct StrategyParams {
        uint256 activation;
        uint256 lastReport;
        uint256 currentDebt;
        uint256 maxDebt;
    }

    // ENUMS
    // Each permissioned function has its own Role.
    // Roles can be combined in any combination or all kept separate.
    // Follows python Enum patterns so the first Enum == 1 and doubles each time.
    enum Roles {
            ADD_STRATEGY_MANAGER, // Can add strategies to the vault.
            REVOKE_STRATEGY_MANAGER, // Can remove strategies from the vault.
            FORCE_REVOKE_MANAGER, // Can force remove a strategy causing a loss.
            ACCOUNTANT_MANAGER, // Can set the accountant that assess fees.
            QUEUE_MANAGER, // Can set the default withdrawal queue.
            REPORTING_MANAGER, // Calls report for strategies.
            DEBT_MANAGER, // Adds and removes debt from strategies.
            MAX_DEBT_MANAGER, // Can set the max debt for a strategy.
            DEPOSIT_LIMIT_MANAGER, // Sets deposit limit and module for the vault.
            WITHDRAW_LIMIT_MANAGER, // Sets the withdraw limit module.
            MINIMUM_IDLE_MANAGER, // Sets the minimum total idle the vault should keep.
            PROFIT_UNLOCK_MANAGER, // Sets the profit_max_unlock_time.
            DEBT_PURCHASER, // Can purchase bad debt from the vault.
            EMERGENCY_MANAGER // Can shutdown vault in an emergency.
        }

    // STRATEGY EVENTS
    event StrategyChanged(address indexed strategy, uint256 changeType);
    event StrategyReported(
        address indexed strategy,
        uint256 gain,
        uint256 loss,
        uint256 currentDebt,
        uint256 protocolFees,
        uint256 totalFees,
        uint256 totalRefunds
    );
    // DEBT MANAGEMENT EVENTS
    event DebtUpdated(
        address indexed strategy,
        uint256 currentDebt,
        uint256 newDebt
    );
    // ROLE UPDATES
    event RoleSet(address indexed account, uint256 role);
    event RoleStatusChanged(uint256 role, uint256 status);
    event UpdateRoleManager(address indexed roleManager);

    event UpdateAccountant(address indexed accountant);
    event UpdateDefaultQueue(address[] newDefaultQueue);
    event UpdateUseDefaultQueue(bool useDefaultQueue);
    event UpdatedMaxDebtForStrategy(
        address indexed sender,
        address indexed strategy,
        uint256 newDebt
    );
    event UpdateDepositLimit(uint256 depositLimit);
    event UpdateMinimumTotalIdle(uint256 minimumTotalIdle);
    event UpdateProfitMaxUnlockTime(uint256 profitMaxUnlockTime);
    event DebtPurchased(address indexed strategy, uint256 amount);
    event Shutdown();

    function setAccountant(address newAccountant) external;

    function setDefaultQueue(address[] memory newDefaultQueue) external;

    function setUseDefaultQueue(bool) external;

    function setDepositLimit(uint256 depositLimit) external;

    function setDepositLimitModule(
        address newDepositLimitModule
    ) external;

    function setWithdrawLimitModule(
        address newWithdrawLimitModule
    ) external;

    function setMinimumTotalIdle(uint256 minimumTotalIdle) external;

    function setProfitMaxUnlockTime(
        uint256 newProfitMaxUnlockTime
    ) external;

    function addRole(address account, uint256 role) external;

    function removeRole(address account, uint256 role) external;

    function setOpenRole(uint256 role) external;

    function closeOpenRole(uint256 role) external;

    function transferRoleManager(address roleManager) external;

    function acceptRoleManager() external;

    function processReport(
        address strategy
    ) external returns (uint256, uint256);

    function buyDebt(address strategy, uint256 amount) external;

    function addStrategy(address newStrategy) external;

    function revokeStrategy(address strategy) external;

    function forceRevokeStrategy(address strategy) external;

    function updateMaxDebtForStrategy(
        address strategy,
        uint256 newMaxDebt
    ) external;

    function updateDebt(
        address strategy,
        uint256 targetDebt
    ) external returns (uint256);

    function shutdownVault() external;

    //// NON-STANDARD ERC-4626 FUNCTIONS \\\\

    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss
    ) external returns (uint256);

    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] memory strategies
    ) external returns (uint256);

    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] memory strategies
    ) external returns (uint256);

    //// NON-STANDARD ERC-20 FUNCTIONS \\\\

    function increaseAllowance(
        address spender,
        uint256 amount
    ) external returns (bool);

    function decreaseAllowance(
        address spender,
        uint256 amount
    ) external returns (bool);

    function permit(
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (bool);

    function addRole(address, Roles) external;

    function removeRole(address, Roles) external;

    function setOpenRole(Roles) external;

    function maxWithdraw(
        address owner,
        uint256 maxLoss
    ) external view returns (uint256);

    function maxWithdraw(
        address owner,
        uint256 maxLoss,
        address[] memory strategies
    ) external view returns (uint256);

    function maxRedeem(
        address owner,
        uint256 maxLoss
    ) external view returns (uint256);

    function maxRedeem(
        address owner,
        uint256 maxLoss,
        address[] memory strategies
    ) external view returns (uint256);

    function unlockedShares() external view returns (uint256);

    function pricePerShare() external view returns (uint256);

    function getDefaultQueue() external view returns (address[] memory);

    function defaultQueue(uint256) external view returns (address);

    function useDefaultQueue() external view returns (bool);

    function totalSupply() external view returns (uint256);

    function minimumTotalIdle() external view returns (uint256);

    function depositLimit() external view returns (uint256);

    function depositLimitModule() external view returns (address);

    function withdrawLimitModule() external view returns (address);

    function accountant() external view returns (address);

    function roleManager() external view returns (address);

    function futureRoleManager() external view returns (address);

    function isShutdown() external view returns (bool);

    function nonces(address) external view returns (uint256);

    function totalIdle() external view returns (uint256);

    function totalDebt() external view returns (uint256);

    function apiVersion() external view returns (string memory);

    function assessShareOfUnrealisedLosses(
        address strategy,
        uint256 assetsNeeded
    ) external view returns (uint256);
}
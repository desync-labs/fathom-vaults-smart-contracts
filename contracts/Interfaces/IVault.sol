// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.16;

import {IERC4626} from "./IERC4626.sol";
import "../VaultStructs.sol";

interface IVault is IERC4626 {
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

    function addRole(address account, bytes32 role) external;

    function removeRole(address account, bytes32 role) external;

    function setOpenRole(bytes32 role) external;

    function closeOpenRole(bytes32 role) external;

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

    function maxWithdraw(
        address owner,
        uint256 maxLoss,
        address[] memory strategies
    ) external returns (uint256);

    function maxRedeem(
        address owner,
        uint256 maxLoss,
        address[] memory strategies
    ) external returns (uint256);

    function unlockedShares() external view returns (uint256);

    function pricePerShare() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function assessShareOfUnrealisedLosses(
        address strategy,
        uint256 assetsNeeded
    ) external view returns (uint256);
}
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import "../VaultStructs.sol";

interface IVault {
    // solhint-disable ordering
    
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
        address sender,
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

    function deposit(uint256 assets, address receiver) external returns (uint256);

    function mint(uint256 shares, address receiver) external returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transfer(address receiver, uint256 amount) external returns (bool);

    function transferFrom(address sender, address receiver, uint256 amount) external returns (bool);

    function balanceOf(address addr) external view returns (uint256);

    function asset() external view returns (address);

    function decimals() external view returns (uint8);

    function totalAssets() external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function previewDeposit(uint256 assets) external view returns (uint256);

    function previewMint(uint256 shares) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function maxDeposit(address receiver) external view returns (uint256);

    function maxMint(address receiver) external view returns (uint256);

    function previewWithdraw(uint256 assets) external view returns (uint256);

    function previewRedeem(uint256 shares) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function getDebt(address strategy) external view returns (uint256);

    function setFees(uint256 totalFees, uint256 totalRefunds, uint256 protocolFees, address protocolFeeRecipient) external;
}
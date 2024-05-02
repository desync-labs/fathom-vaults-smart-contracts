// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

interface IAccountant {
    // Events
    event VaultChanged(address indexed vault, ChangeType change);
    event UpdateDefaultFeeConfig(Fee defaultFeeConfig);
    event SetFutureFeeManager(address indexed futureFeeManager);
    event NewFeeManager(address indexed feeManager);
    event UpdateVaultManager(address indexed newVaultManager);
    event UpdateFeeRecipient(address indexed oldFeeRecipient, address indexed newFeeRecipient);
    event UpdateCustomFeeConfig(address indexed vault, Fee customConfig);
    event RemovedCustomFeeConfig(address indexed vault);
    event UpdateMaxLoss(uint256 maxLoss);
    event DistributeRewards(address indexed token, uint256 rewards);

    // Errors
    error Unauthorized();
    error VaultNotFound();
    error ZeroAddress();
    error VaultAlreadyAdded();
    error ValueTooHigh();
    error NoCustomFeesSet();
    error NotFutureFeeManager();
    error TooMuchGain();
    error TooMuchLoss();

    // Methods
    function addVault(address vault) external;
    function removeVault(address vault) external;
    // solhint-disable-next-line max-line-length
    function updateDefaultConfig(uint16 defaultManagement, uint16 defaultPerformance, uint16 defaultRefund, uint16 defaultMaxFee, uint16 defaultMaxGain, uint16 defaultMaxLoss) external;
    // solhint-disable-next-line max-line-length
    function setCustomConfig(address vault, uint16 customManagement, uint16 customPerformance, uint16 customRefund, uint16 customMaxFee, uint16 customMaxGain, uint16 customMaxLoss) external;
    function removeCustomConfig(address vault) external;
    function turnOffHealthCheck(address vault, address strategy) external;
    function redeemUnderlying(address vault) external;
    function redeemUnderlying(address vault, uint256 amount) external;
    function setMaxLoss(uint256 _maxLoss) external;
    function distribute(address token) external;
    function distribute(address token, uint256 amount) external;
    function setFutureFeeManager(address _futureFeeManager) external;
    function acceptFeeManager() external;
    function setVaultManager(address newVaultManager) external;
    function setFeeRecipient(address newFeeRecipient) external;
    function report(address strategy, uint256 gain, uint256 loss) external returns (uint256 totalFees, uint256 totalRefunds);
    function useCustomConfig(address vault) external view returns (bool);
    function getVaultConfig(address vault) external view returns (Fee memory);
}
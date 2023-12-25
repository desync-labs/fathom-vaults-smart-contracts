// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../CommonErrors.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IVaultPackage.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../VaultStorage.sol";
import "../interfaces/IVaultEvents.sol";
import "../interfaces/IAccountant.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IDepositLimitModule.sol";
import "../interfaces/IWithdrawLimitModule.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IStrategyManager.sol";
import "../interfaces/ISharesManager.sol";
import "../interfaces/IConfigSetters.sol";
import "../interfaces/IGovernance.sol";

/// @title Fathom Vault
/// @notice The Fathom Vault is designed as a non-opinionated system to distribute funds of
/// depositors for a specific `asset` into different opportunities (aka Strategies)
/// and manage accounting in a robust way.
contract VaultPackage is AccessControl, IVault, ReentrancyGuard, VaultStorage, IVaultEvents {
    /// @notice Factory address
    address public factoryAddress;

    function initialize(
        uint256 _profitMaxUnlockTime,
        address payable _strategyManagerAddress,
        address _sharesManagerAddress,
        address payable _settersAddress,
        address _governanceAddress
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (initialized == true) {
            revert AlreadyInitialized();
        }

        factoryAddress = msg.sender;
        // Must be less than one year for report cycles
        if (_profitMaxUnlockTime > ONE_YEAR) {
            revert ProfitUnlockTimeTooLong();
        }

        profitMaxUnlockTime = _profitMaxUnlockTime;
        strategyManager = _strategyManagerAddress;
        sharesManager = _sharesManagerAddress;
        configSetters = _settersAddress;
        governance = _governanceAddress;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DEPOSIT_LIMIT_MANAGER, msg.sender);
        _grantRole(ADD_STRATEGY_MANAGER, msg.sender);
        _grantRole(MAX_DEBT_MANAGER, msg.sender);
        _grantRole(DEBT_MANAGER, msg.sender);
        _grantRole(REPORTING_MANAGER, msg.sender);

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPE_HASH,
                keccak256(bytes(ISharesManager(sharesManager).name())), // "Fathom Vault" in the example
                keccak256(bytes(API_VERSION)), // API_VERSION in the example
                block.chainid, // Current chain ID
                address(this) // Address of the contract
            )
        );

        initialized = true;
    }

    /// @notice Set the new default queue array.
    /// @dev Will check each strategy to make sure it is active.
    /// @param newDefaultQueue The new default queue array.
    function setDefaultQueue(address[] calldata newDefaultQueue) external override onlyRole(QUEUE_MANAGER) {
        IConfigSetters(configSetters).setDefaultQueue(newDefaultQueue);
    }

    /// @notice Set a new value for `use_default_queue`.
    /// @dev If set `True` the default queue will always be
    /// used no matter whats passed in.
    /// @param _useDefaultQueue new value.
    function setUseDefaultQueue(bool _useDefaultQueue) external override onlyRole(QUEUE_MANAGER) {
        IConfigSetters(configSetters).setUseDefaultQueue(_useDefaultQueue);
    }

    /// @notice Set the new deposit limit.
    /// @dev Can not be changed if a depositLimitModule
    /// is set or if shutdown.
    /// @param _depositLimit The new deposit limit.
    function setDepositLimit(uint256 _depositLimit) external override onlyRole(DEPOSIT_LIMIT_MANAGER) {
        ISharesManager(sharesManager).setDepositLimit(_depositLimit);
    }

    /// @notice Set a contract to handle the deposit limit.
    /// @dev The default `depositLimit` will need to be set to
    /// max uint256 since the module will override it.
    /// @param _depositLimitModule Address of the module.
    function setDepositLimitModule(address _depositLimitModule) external override onlyRole(DEPOSIT_LIMIT_MANAGER) {
        IConfigSetters(configSetters).setDepositLimitModule(_depositLimitModule);
    }

    /// @notice Set a contract to handle the withdraw limit.
    /// @dev This will override the default `maxWithdraw`.
    /// @param _withdrawLimitModule Address of the module.
    function setWithdrawLimitModule(address _withdrawLimitModule) external override onlyRole(WITHDRAW_LIMIT_MANAGER) {
        IConfigSetters(configSetters).setWithdrawLimitModule(_withdrawLimitModule);
    }

    /// @notice Set the new minimum total idle.
    /// @param _minimumTotalIdle The new minimum total idle.
    function setMinimumTotalIdle(uint256 _minimumTotalIdle) external override onlyRole(MINIMUM_IDLE_MANAGER) {
        IConfigSetters(configSetters).setMinimumTotalIdle(_minimumTotalIdle);
    }

    /// @notice Set the new profit max unlock time.
    /// @dev The time is denominated in seconds and must be less than 1 year.
    ///  We only need to update locking period if setting to 0,
    ///  since the current period will use the old rate and on the next
    ///  report it will be reset with the new unlocking time.
    ///  Setting to 0 will cause any currently locked profit to instantly
    /// unlock and an immediate increase in the vaults Price Per Share.
    /// @param _newProfitMaxUnlockTime The new profit max unlock time.
    function setProfitMaxUnlockTime(uint256 _newProfitMaxUnlockTime) external override onlyRole(PROFIT_UNLOCK_MANAGER) {
        IConfigSetters(configSetters).setProfitMaxUnlockTime(_newProfitMaxUnlockTime);
    }

    /// @notice Set the new accountant address.
    /// @param newAccountant The new accountant address.
    function setAccountant(address newAccountant) external override onlyRole(ACCOUNTANT_MANAGER) {
        IConfigSetters(configSetters).setAccountant(newAccountant);
    }

    /// @notice Process the report of a strategy.
    /// @param strategy The strategy to process the report for.
    /// @return The gain and loss of the strategy.
    function processReport(address strategy) external override onlyRole(REPORTING_MANAGER) nonReentrant returns (uint256, uint256) {
        return IStrategyManager(strategyManager).processReport(strategy);
    }

    /// @notice Used for governance to buy bad debt from the vault.
    /// @dev This should only ever be used in an emergency in place
    /// of force revoking a strategy in order to not report a loss.
    /// It allows the DEBT_PURCHASER role to buy the strategies debt
    /// for an equal amount of `asset`.
    /// @param strategy The strategy to buy the debt for
    /// @param amount The amount of debt to buy from the vault.
    function buyDebt(address strategy, uint256 amount) external override onlyRole(DEBT_PURCHASER) nonReentrant {
        IGovernance(governance).buyDebt(strategy, amount);
    }

    /// @notice Add a new strategy.
    /// @param newStrategy The new strategy to add.
    function addStrategy(address newStrategy) external override onlyRole(ADD_STRATEGY_MANAGER) {
        IStrategyManager(strategyManager).addStrategy(newStrategy);
    }

    /// @notice Revoke a strategy.
    /// @param strategy The strategy to revoke.
    function revokeStrategy(address strategy) external override onlyRole(REVOKE_STRATEGY_MANAGER) {
        IStrategyManager(strategyManager).revokeStrategy(strategy, false);
    }

    /// @notice Force revoke a strategy.
    /// @dev The vault will remove the strategy and write off any debt left
    /// in it as a loss. This function is a dangerous function as it can force a
    /// strategy to take a loss. All possible assets should be removed from the
    /// strategy first via update_debt. If a strategy is removed erroneously it
    /// can be re-added and the loss will be credited as profit. Fees will apply.
    /// @param strategy The strategy to force revoke.
    function forceRevokeStrategy(address strategy) external override onlyRole(FORCE_REVOKE_MANAGER) {
        IStrategyManager(strategyManager).revokeStrategy(strategy, true);
    }

    /// @notice Update the max debt for a strategy.
    /// @param strategy The strategy to update the max debt for.
    /// @param newMaxDebt The new max debt for the strategy.
    function updateMaxDebtForStrategy(address strategy, uint256 newMaxDebt) external override onlyRole(MAX_DEBT_MANAGER) {
        // Delegate call to StrategyManager
        IStrategyManager(strategyManager).updateMaxDebtForStrategy(strategy, newMaxDebt);
    }

    /// @notice Update the debt for a strategy.
    /// @param strategy The strategy to update the debt for.
    /// @param targetDebt The target debt for the strategy.
    /// @return The amount of debt added or removed.
    function updateDebt(
        address sender,
        address strategy,
        uint256 targetDebt
    ) external override onlyRole(DEBT_MANAGER) nonReentrant returns (uint256) {
        return IStrategyManager(strategyManager).updateDebt(sender, strategy, targetDebt);
    }

    /// @notice Shutdown the vault.
    function shutdownVault() external override onlyRole(EMERGENCY_MANAGER) {
        IGovernance(governance).shutdownVault();
    }

    /// @notice Deposit assets into the vault.
    /// @param assets The amount of assets to deposit.
    /// @param receiver The address to receive the shares.
    /// @return The amount of shares minted.
    function deposit(uint256 assets, address receiver) external override nonReentrant returns (uint256) {
        return ISharesManager(sharesManager).deposit(msg.sender, receiver, assets);
    }

    /// @notice Mint shares for the receiver.
    /// @param shares The amount of shares to mint.
    /// @param receiver The address to receive the shares.
    /// @return The amount of assets deposited.
    function mint(uint256 shares, address receiver) external override nonReentrant returns (uint256) {
        return ISharesManager(sharesManager).mint(msg.sender, receiver, shares);
    }

    /// @notice Withdraw an amount of asset to `receiver` burning `owner`s shares.
    /// @dev The default behavior is to not allow any loss.
    /// @param assets The amount of asset to withdraw.
    /// @param receiver The address to receive the assets.
    /// @param owner The address who's shares are being burnt.
    /// @param maxLoss Optional amount of acceptable loss in Basis Points.
    /// @param _strategies Optional array of strategies to withdraw from.
    /// @return The amount of shares actually burnt.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] calldata _strategies
    ) external override nonReentrant returns (uint256) {
        return ISharesManager(sharesManager).withdraw(assets, receiver, owner, maxLoss, _strategies);
    }

    /// @notice Redeems an amount of shares of `owners` shares sending funds to `receiver`.
    /// @dev The default behavior is to allow losses to be realized.
    /// @param shares The amount of shares to burn.
    /// @param receiver The address to receive the assets.
    /// @param owner The address who's shares are being burnt.
    /// @param maxLoss Optional amount of acceptable loss in Basis Points.
    /// @param _strategies Optional array of strategies to withdraw from.
    /// @return The amount of assets actually withdrawn.
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] calldata _strategies
    ) external override nonReentrant returns (uint256) {
        return ISharesManager(sharesManager).redeem(shares, receiver, owner, maxLoss, _strategies);
    }

    /// @notice Approve an address to spend the vault's shares.
    /// @param spender The address to approve.
    /// @param amount The amount of shares to approve.
    /// @return True if the approval was successful.
    function approve(address spender, uint256 amount) external override returns (bool) {
        return ISharesManager(sharesManager).approve(msg.sender, spender, amount);
    }

    /// @notice Transfer shares to a receiver.
    /// @param receiver The address to transfer shares to.
    /// @param amount The amount of shares to transfer.
    /// @return True if the transfer was successful.
    function transfer(address receiver, uint256 amount) external override returns (bool) {
        if (receiver == address(this) || receiver == address(0)) {
            revert ZeroAddress();
        }
        ISharesManager(sharesManager).transfer(msg.sender, receiver, amount);
        return true;
    }

    /// @notice Transfer shares from a sender to a receiver.
    /// @param sender The address to transfer shares from.
    /// @param receiver The address to transfer shares to.
    /// @param amount The amount of shares to transfer.
    /// @return True if the transfer was successful.
    function transferFrom(address sender, address receiver, uint256 amount) external override returns (bool) {
        if (receiver == address(this) || receiver == address(0)) {
            revert ZeroAddress();
        }
        return ISharesManager(sharesManager).transferFrom(sender, receiver, amount);
    }

    /// @notice Increase the allowance for a spender.
    /// @param spender The address to increase the allowance for.
    /// @param amount The amount to increase the allowance by.
    /// @return True if the increase was successful.
    function increaseAllowance(address spender, uint256 amount) external override returns (bool) {
        return ISharesManager(sharesManager).increaseAllowance(msg.sender, spender, amount);
    }

    /// @notice Decrease the allowance for a spender.
    /// @param spender The address to decrease the allowance for.
    /// @param amount The amount to decrease the allowance by.
    /// @return True if the decrease was successful.
    function decreaseAllowance(address spender, uint256 amount) external override returns (bool) {
        return ISharesManager(sharesManager).decreaseAllowance(msg.sender, spender, amount);
    }

    /// @notice Approve an address to spend the vault's shares.
    /// @param owner The address to approve.
    /// @param spender The address to approve.
    /// @param amount The amount of shares to approve.
    /// @param deadline The deadline for the permit.
    /// @param v The v component of the signature.
    /// @param r The r component of the signature.
    /// @param s The s component of the signature.
    /// @return True if the approval was successful.
    function permit(
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override returns (bool) {
        return ISharesManager(sharesManager).permit(owner, spender, amount, deadline, v, r, s);
    }

    /// @notice Get the maximum amount of assets that can be withdrawn.
    /// @dev Complies to normal 4626 interface and takes custom params.
    /// @param owner The address that owns the shares.
    /// @param maxLoss Custom maxLoss if any.
    /// @param _strategies Custom strategies queue if any.
    /// @return The maximum amount of assets that can be withdrawn.
    function maxWithdraw(address owner, uint256 maxLoss, address[] calldata _strategies) external override returns (uint256) {
        return ISharesManager(sharesManager).maxWithdraw(owner, maxLoss, _strategies);
    }

    /// @notice Get the maximum amount of shares that can be redeemed.
    /// @dev Complies to normal 4626 interface and takes custom params.
    /// @param owner The address that owns the shares.
    /// @param maxLoss Custom maxLoss if any.
    /// @param _strategies Custom strategies queue if any.
    /// @return The maximum amount of shares that can be redeemed.
    function maxRedeem(address owner, uint256 maxLoss, address[] calldata _strategies) external override returns (uint256) {
        return ISharesManager(sharesManager).maxRedeem(owner, maxLoss, _strategies);
    }

    function setFees(
        uint256 totalFees,
        uint256 totalRefunds,
        uint256 protocolFees,
        address protocolFeeRecipient
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        return IStrategyManager(strategyManager).setFees(totalFees, totalRefunds, protocolFees, protocolFeeRecipient);
    }

    /// @notice Get the amount of shares that have been unlocked.
    /// @return The amount of shares that are have been unlocked.
    function unlockedShares() external view override returns (uint256) {
        return ISharesManager(sharesManager).unlockedShares();
    }

    /// @notice Get the price per share (pps) of the vault.
    /// @dev This value offers limited precision. Integrations that require
    /// exact precision should use convertToAssets or convertToShares instead.
    /// @return The price per share.
    function pricePerShare() external view override returns (uint256) {
        return _convertToAssets(10 ** ISharesManager(sharesManager).decimals(), Rounding.ROUND_DOWN);
    }

    /// @notice Get the balance of a user.
    /// @param addr The address to get the balance of.
    /// @return The balance of the user.
    function balanceOf(address addr) external view override returns (uint256) {
        return ISharesManager(sharesManager).balanceOf(addr);
    }

    /// @notice Get the total supply of shares.
    /// @return The total supply of shares.
    function totalSupply() external view override returns (uint256) {
        return ISharesManager(sharesManager).totalSupply();
    }

    /// @notice Get the address of the asset.
    /// @return The address of the asset.
    function asset() external view override returns (address) {
        return ISharesManager(sharesManager).asset();
    }

    /// @notice Get the number of decimals of the asset/share.
    /// @return The number of decimals of the asset/share.
    function decimals() external view override returns (uint8) {
        return ISharesManager(sharesManager).decimals();
    }

    /// @notice Get the total assets held by the vault.
    /// @return The total assets held by the vault.
    function totalAssets() external view override returns (uint256) {
        return ISharesManager(sharesManager).totalAssets();
    }

    /// @notice Convert an amount of assets to shares.
    /// @param assets The amount of assets to convert.
    /// @return The amount of shares.
    function convertToShares(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, Rounding.ROUND_DOWN);
    }

    /// @notice Preview the amount of shares that would be minted for a deposit.
    /// @param assets The amount of assets to deposit.
    /// @return The amount of shares that would be minted.
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, Rounding.ROUND_DOWN);
    }

    /// @notice Preview the amount of assets that would be deposited for a mint.
    /// @param shares The amount of shares to mint.
    /// @return The amount of assets that would be deposited.
    function previewMint(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, Rounding.ROUND_UP);
    }

    /// @notice Convert an amount of shares to assets.
    /// @param shares The amount of shares to convert.
    /// @return The amount of assets.
    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, Rounding.ROUND_DOWN);
    }

    /// @notice Get the maximum amount of assets that can be deposited.
    /// @param receiver The address that will receive the shares.
    /// @return The maximum amount of assets that can be deposited.
    function maxDeposit(address receiver) external view override returns (uint256) {
        return ISharesManager(sharesManager).maxDeposit(receiver);
    }

    /// @notice Get the maximum amount of shares that can be minted.
    /// @param receiver The address that will receive the shares.
    /// @return The maximum amount of shares that can be minted.
    function maxMint(address receiver) external view override returns (uint256) {
        return ISharesManager(sharesManager).maxMint(receiver);
    }

    /// @notice Preview the amount of shares that would be redeemed for a withdraw.
    /// @param assets The amount of assets to withdraw.
    /// @return The amount of shares that would be redeemed.
    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, Rounding.ROUND_UP);
    }

    /// @notice Preview the amount of assets that would be withdrawn for a redeem.
    /// @param shares The amount of shares to redeem.
    /// @return The amount of assets that would be withdrawn.
    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, Rounding.ROUND_DOWN);
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return ISharesManager(sharesManager).allowance(owner, spender);
    }

    function getDebt(address strategy) external view override returns (uint256) {
        return IStrategyManager(strategyManager).getDebt(strategy);
    }

    function _burnShares(uint256 shares, address owner) internal {
        ISharesManager(sharesManager).burnShares(shares, owner);
    }

    /// @notice Used only to transfer tokens that are not the type managed by this Vault.
    /// Used to handle non-compliant tokens like USDT
    function _erc20SafeTransferFrom(address token, address sender, address receiver, uint256 amount) internal {
        ISharesManager(sharesManager).erc20SafeTransferFrom(token, sender, receiver, amount);
    }

    /// @notice Used only to send tokens that are not the type managed by this Vault.
    /// Used to handle non-compliant tokens like USDT
    function _erc20SafeTransfer(address token, address receiver, uint256 amount) internal {
        ISharesManager(sharesManager).erc20SafeTransfer(token, receiver, amount);
    }

    function _issueShares(uint256 shares, address recipient) internal {
        ISharesManager(sharesManager).issueShares(shares, recipient);
    }

    /// @notice Issues shares that are worth 'amount' in the underlying token (asset).
    /// WARNING: this takes into account that any new assets have been summed
    /// to totalAssets (otherwise pps will go down).
    function _issueSharesForAmount(uint256 amount, address recipient) internal returns (uint256) {
        return ISharesManager(sharesManager).issueSharesForAmount(amount, recipient);
    }

    /// @notice assets = shares * (totalAssets / totalSupply) --- (== pricePerShare * shares)
    function _convertToAssets(uint256 shares, Rounding rounding) internal view returns (uint256) {
        return ISharesManager(sharesManager).convertToAssets(shares, rounding);
    }

    /// @notice shares = amount * (totalSupply / totalAssets) --- (== amount / pricePerShare)
    function _convertToShares(uint256 assets, Rounding rounding) internal view returns (uint256) {
        return ISharesManager(sharesManager).convertToShares(assets, rounding);
    }
}

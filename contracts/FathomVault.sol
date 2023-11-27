// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "./Interfaces/IVault.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./VaultStorage.sol";
import "./Interfaces/IVaultEvents.sol";
import "./Interfaces/IAccountant.sol";
import "./Interfaces/IStrategy.sol";
import "./Interfaces/IDepositLimitModule.sol";
import "./Interfaces/IWithdrawLimitModule.sol";
import "./Interfaces/IFactory.sol";
import "./Interfaces/IStrategyManager.sol";
import "./Interfaces/ISharesManager.sol";

/**
@title Yearn V3 Vault
@notice The Yearn VaultV3 is designed as a non-opinionated system to distribute funds of 
depositors for a specific `asset` into different opportunities (aka Strategies)
and manage accounting in a robust way.
*/

// Solidity version of the Vyper contract
contract FathomVault is AccessControl, IVault, ReentrancyGuard, VaultStorage, IVaultEvents {
    // solhint-disable not-rely-on-time
    // solhint-disable function-max-lines
    // solhint-disable code-complexity
    // solhint-disable var-name-mixedcase
    // solhint-disable max-line-length

    using Math for uint256;

    error InvalidAssetDecimals();
    error ProfitUnlockTimeTooLong();
    error ERC20InsufficientAllowance();
    error InsufficientFunds();
    error ZeroAddress();
    error ERC20PermitExpired();
    error ERC20PermitInvalidSignature();
    error InsufficientShares();
    error InactiveStrategy();
    error StrategyIsShutdown();
    error ExceedDepositLimit();
    error ZeroValue();
    error MaxLoss();
    error InsufficientAssets();
    error TooMuchLoss();
    error InvalidAsset();
    error StrategyAlreadyActive();
    error StrategyHasDebt();
    error DebtDidntChange();
    error StrategyHasUnrealisedLosses();
    error DebtHigherThanMaxDebt();
    error UsingModule();
    error UsingDepositLimit();
    error StrategyDebtIsLessThanAssetsNeeded();

    // Factory address
    address public immutable FACTORY;
    uint256 public immutable ONE_YEAR = 31556952;

    // Constructor
    constructor(
        uint256 _profitMaxUnlockTime,
        address _strategyManagerAddress,
        address _sharesManagerAddress
    ) {
        FACTORY = msg.sender;
        // Must be less than one year for report cycles
        if (_profitMaxUnlockTime > ONE_YEAR) {
            revert ProfitUnlockTimeTooLong();
        }

        profitMaxUnlockTime = _profitMaxUnlockTime;

        strategyManager = _strategyManagerAddress;
        sharesManager = _sharesManagerAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DEPOSIT_LIMIT_MANAGER, msg.sender);
        _grantRole(ADD_STRATEGY_MANAGER, msg.sender);
        _grantRole(MAX_DEBT_MANAGER, msg.sender);
        _grantRole(DEBT_MANAGER, msg.sender);
        _grantRole(REPORTING_MANAGER, msg.sender);

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPE_HASH,
                keccak256(bytes(ISharesManager(sharesManager).name())), // "Yearn Vault" in the example
                keccak256(bytes(API_VERSION)), // API_VERSION in the example
                block.chainid, // Current chain ID
                address(this) // Address of the contract
            )
        );

    }

    // SHARE MANAGEMENT
    // ERC20
    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        ISharesManager(sharesManager).spendAllowance(owner, spender, amount);
    }

    function _increaseAllowance(address owner, address spender, uint256 amount) internal returns (bool) {
        return ISharesManager(sharesManager).increaseAllowance(owner, spender, amount);
    }

    function _decreaseAllowance(address owner, address spender, uint256 amount) internal returns (bool) {
        return ISharesManager(sharesManager).decreaseAllowance(owner, spender, amount);
    }

    function _permit(
        address owner, 
        address spender, 
        uint256 amount, 
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) internal returns (bool) {
        return ISharesManager(sharesManager).permit(owner, spender, amount, deadline, v, r, s);
    }

    function _burnShares(uint256 shares, address owner) internal {
        ISharesManager(sharesManager).burnShares(shares, owner);
    }

    // Returns the amount of shares that have been unlocked.
    // To avoid sudden pricePerShare spikes, profits must be processed 
    // through an unlocking period. The mechanism involves shares to be 
    // minted to the vault which are unlocked gradually over time. Shares 
    // that have been locked are gradually unlocked over profitMaxUnlockTime.
    function _unlockedShares() internal view returns (uint256) {
        return ISharesManager(sharesManager).unlockedShares();
    }
    
    // Need to account for the shares issued to the vault that have unlocked.
    function _totalSupply() internal view returns (uint256) {
        return totalSupplyAmount - _unlockedShares();
    }

    // Burns shares that have been unlocked since last update. 
    // In case the full unlocking period has passed, it stops the unlocking.
    function _burnUnlockedShares() internal {
        ISharesManager(sharesManager).burnUnlockedShares();
    }

    // assets = shares * (total_assets / total_supply) --- (== price_per_share * shares)
    function _convertToAssets(uint256 shares, Rounding rounding) internal view returns (uint256) {
        return ISharesManager(sharesManager).convertToAssets(shares, rounding);
    }

    // shares = amount * (total_supply / total_assets) --- (== amount / price_per_share)
    function _convertToShares(uint256 assets, Rounding rounding) internal view returns (uint256) {
        return ISharesManager(sharesManager).convertToShares(assets, rounding);
    }

    // Used only to approve tokens that are not the type managed by this Vault.
    // Used to handle non-compliant tokens like USDT
    function _erc20SafeApprove(address token, address spender, uint256 amount) internal {
        ISharesManager(sharesManager).erc20SafeApprove(token, spender, amount);
    }

    // Used only to transfer tokens that are not the type managed by this Vault.
    // Used to handle non-compliant tokens like USDT
    function _erc20SafeTransferFrom(address token, address sender, address receiver, uint256 amount) internal {
        ISharesManager(sharesManager).erc20SafeTransferFrom(token, sender, receiver, amount);
    }

    // Used only to send tokens that are not the type managed by this Vault.
    // Used to handle non-compliant tokens like USDT
    function _erc20SafeTransfer(address token, address receiver, uint256 amount) internal {
        ISharesManager(sharesManager).erc20SafeTransfer(token, receiver, amount);
    }

    function _issueShares(uint256 shares, address recipient) internal {
        ISharesManager(sharesManager).issueShares(shares, recipient);
    }

    // Issues shares that are worth 'amount' in the underlying token (asset).
    // WARNING: this takes into account that any new assets have been summed 
    // to total_assets (otherwise pps will go down).
    function _issueSharesForAmount(uint256 amount, address recipient) internal returns (uint256) {
        return ISharesManager(sharesManager).issueSharesForAmount(amount, recipient);
    }


    // ERC4626
    function _maxDeposit(address receiver) internal view returns (uint256) {
        return ISharesManager(sharesManager).maxDeposit(receiver);
    }

    // @dev Returns the max amount of `asset` an `owner` can withdraw.
    // This will do a full simulation of the withdraw in order to determine
    // how much is currently liquid and if the `max_loss` would allow for the 
    // tx to not revert.
    // This will track any expected loss to check if the tx will revert, but
    // not account for it in the amount returned since it is unrealised and 
    // therefore will not be accounted for in the conversion rates.
    // i.e. If we have 100 debt and 10 of unrealised loss, the max we can get
    // out is 90, but a user of the vault will need to call withdraw with 100
    // in order to get the full 90 out.
    function _maxWithdraw(address owner, uint256 _maxLoss, address[] memory _strategies)
        internal
        returns (uint256)
    {
        return ISharesManager(sharesManager).maxWithdraw(owner, _maxLoss, _strategies);
    }

    // Returns the share of losses that a user would take if withdrawing from this strategy
    // e.g. if the strategy has unrealised losses for 10% of its current debt and the user 
    // wants to withdraw 1000 tokens, the losses that he will take are 100 token
    function _assessShareOfUnrealisedLosses(address strategy, uint256 assetsNeeded) internal view returns (uint256) {
        return ISharesManager(sharesManager).assessShareOfUnrealisedLosses(strategy, assetsNeeded);
    }

    // This takes the amount denominated in asset and performs a {redeem}
    // with the corresponding amount of shares.
    // We use {redeem} to natively take on losses without additional non-4626 standard parameters.
    function _withdrawFromStrategy(address strategy, uint256 assetsToWithdraw) internal {
        ISharesManager(sharesManager).withdrawFromStrategy(strategy, assetsToWithdraw);
    }

    // STRATEGY MANAGEMENT
    function _addStrategy(address newStrategy) internal {
        // Delegate call to StrategyManager
        IStrategyManager(strategyManager).addStrategy(newStrategy);
    }

    function _revokeStrategy(address strategy, bool force) internal {
        // Delegate call to StrategyManager
        IStrategyManager(strategyManager).revokeStrategy(strategy, force);
    }

    // DEBT MANAGEMENT
    // The vault will re-balance the debt vs target debt. Target debt must be
    // smaller or equal to strategy's max_debt. This function will compare the 
    // current debt with the target debt and will take funds or deposit new 
    // funds to the strategy. 

    // The strategy can require a maximum amount of funds that it wants to receive
    // to invest. The strategy can also reject freeing funds if they are locked.
    function _updateDebt(address strategy, uint256 targetDebt) internal returns (uint256) {
        if (strategies[strategy].currentDebt != targetDebt && totalIdleAmount <= minimumTotalIdle) {
            revert InsufficientFunds();
        }
        return IStrategyManager(strategyManager).updateDebt(strategy, targetDebt, sharesManager);
    }

    // ACCOUNTING MANAGEMENT
    // Processing a report means comparing the debt that the strategy has taken 
    // with the current amount of funds it is reporting. If the strategy owes 
    // less than it currently has, it means it has had a profit, else (assets < debt) 
    // it has had a loss.

    // Different strategies might choose different reporting strategies: pessimistic, 
    // only realised P&L, ... The best way to report depends on the strategy.

    // The profit will be distributed following a smooth curve over the vaults 
    // profit_max_unlock_time seconds. Losses will be taken immediately, first from the 
    // profit buffer (avoiding an impact in pps), then will reduce pps.

    // Any applicable fees are charged and distributed during the report as well
    // to the specified recipients.
    function _processReport(address strategy) internal returns (uint256, uint256) {
        // Make sure we have a valid strategy.
        if (strategies[strategy].activation == 0) {
            revert InactiveStrategy();
        }

        // Burn shares that have been unlocked since the last update
        _burnUnlockedShares();

        (uint256 gain, uint256 loss) = _assessProfitAndLoss(strategy);

        FeeAssessment memory fees = _assessFees(strategy, gain, loss);

        ShareManagement memory shares = _calculateShareManagement(loss, fees.totalFees, fees.protocolFees);

        (uint256 previouslyLockedShares, uint256 newlyLockedShares) = _handleShareBurnsAndIssues(shares, fees, gain, loss, strategy);

        _manageUnlockingOfShares(previouslyLockedShares, newlyLockedShares);

        // Record the report of profit timestamp.
        strategies[strategy].lastReport = block.timestamp;

        // We have to recalculate the fees paid for cases with an overall loss.
        emit StrategyReported(
            strategy,
            gain,
            loss,
            strategies[strategy].currentDebt,
            _convertToAssets(shares.protocolFeesShares, Rounding.ROUND_DOWN),
            _convertToAssets(shares.protocolFeesShares + shares.accountantFeesShares, Rounding.ROUND_DOWN),
            fees.totalRefunds
        );

        return (gain, loss);
    }

    // Assess the profit and loss of a strategy.
    function _assessProfitAndLoss(address strategy) internal view returns (uint256 gain, uint256 loss) {
        // Vault assesses profits using 4626 compliant interface.
        // NOTE: It is important that a strategies `convertToAssets` implementation
        // cannot be manipulated or else the vault could report incorrect gains/losses.
        uint256 strategyShares = IStrategy(strategy).balanceOf(address(this));
        // How much the vaults position is worth.
        uint256 currentTotalAssets = IStrategy(strategy).convertToAssets(strategyShares);
        // How much the vault had deposited to the strategy.
        uint256 currentDebt = strategies[strategy].currentDebt;

        uint256 _gain = 0;
        uint256 _loss = 0;

        // Compare reported assets vs. the current debt.
        if (currentTotalAssets > currentDebt) {
            // We have a gain.
            _gain = currentTotalAssets - currentDebt;
        } else {
            // We have a loss.
            _loss = currentDebt - currentTotalAssets;
        }

        return (_gain, _loss);
    }

    // Calculate and distribute any fees and refunds from the strategy's performance.
    function _assessFees(address strategy, uint256 gain, uint256 loss) internal returns (FeeAssessment memory) {
        FeeAssessment memory fees;

        // If accountant is not set, fees and refunds remain unchanged.
        if (accountant != address(0)) {
            (fees.totalFees, fees.totalRefunds) = IAccountant(accountant).report(strategy, gain, loss);

            // Protocol fees will be 0 if accountant fees are 0.
            if (fees.totalFees > 0) {
                uint16 protocolFeeBps;
                // Get the config for this vault.
                (protocolFeeBps, fees.protocolFeeRecipient) = IFactory(FACTORY).protocolFeeConfig();
                
                if (protocolFeeBps > 0) {
                    // Protocol fees are a percent of the fees the accountant is charging.
                    fees.protocolFees = fees.totalFees * uint256(protocolFeeBps) / MAX_BPS;
                }
            }
        }

        return fees;
    }

    // Calculate share management based on gains, losses, and fees.
    function _calculateShareManagement(uint256 loss, uint256 totalFees, uint256 protocolFees) internal view returns (ShareManagement memory) {
        // `shares_to_burn` is derived from amounts that would reduce the vaults PPS.
        // NOTE: this needs to be done before any pps changes
        ShareManagement memory shares;

        // Only need to burn shares if there is a loss or fees.
        if (loss + totalFees > 0) {
            // The amount of shares we will want to burn to offset losses and fees.
            shares.sharesToBurn += _convertToShares(loss + totalFees, Rounding.ROUND_UP);

            // Vault calculates the amount of shares to mint as fees before changing totalAssets / totalSupply.
            if (totalFees > 0) {
                // Accountant fees are total fees - protocol fees.
                shares.accountantFeesShares = _convertToShares(totalFees - protocolFees, Rounding.ROUND_DOWN);
                if (protocolFees > 0) {
                    shares.protocolFeesShares = _convertToShares(protocolFees, Rounding.ROUND_DOWN);
                }
            }
        }

        return shares;
    }

    // Handle the burning and issuing of shares based on the strategy's report.
    function _handleShareBurnsAndIssues(
        ShareManagement memory shares, 
        FeeAssessment memory fees, 
        uint256 gain, 
        uint256 loss, 
        address strategy
    ) internal returns (uint256 previouslyLockedShares, uint256 newlyLockedShares) {
        // Shares to lock is any amounts that would otherwise increase the vaults PPS.
        uint256 _newlyLockedShares;
        if (fees.totalRefunds > 0) {
            // Make sure we have enough approval and enough asset to pull.
            fees.totalRefunds = Math.min(fees.totalRefunds, Math.min(ISharesManager(sharesManager).balanceOf(accountant), ISharesManager(sharesManager).allowance(accountant, address(this))));
            // Transfer the refunded amount of asset to the vault.
            _erc20SafeTransferFrom(sharesManager, accountant, address(this), fees.totalRefunds);
            // Update storage to increase total assets.
            totalIdleAmount += fees.totalRefunds;
        }

        // Record any reported gains.
        if (gain > 0) {
            // NOTE: this will increase total_assets
            strategies[strategy].currentDebt += gain;
            totalDebtAmount += gain;
        }

        // Mint anything we are locking to the vault.
        if (gain + fees.totalRefunds > 0 && profitMaxUnlockTime != 0) {
            _newlyLockedShares = _issueSharesForAmount(gain + fees.totalRefunds, address(this));
        }

        // Strategy is reporting a loss
        if (loss > 0) {
            strategies[strategy].currentDebt -= loss;
            totalDebtAmount -= loss;
        }

        // NOTE: should be precise (no new unlocked shares due to above's burn of shares)
        // newly_locked_shares have already been minted / transferred to the vault, so they need to be subtracted
        // no risk of underflow because they have just been minted.
        uint256 _previouslyLockedShares = _balanceOf[address(this)] - _newlyLockedShares;

        // Now that pps has updated, we can burn the shares we intended to burn as a result of losses/fees.
        // NOTE: If a value reduction (losses / fees) has occurred, prioritize burning locked profit to avoid
        // negative impact on price per share. Price per share is reduced only if losses exceed locked value.
        if (shares.sharesToBurn > 0) {
            // Cant burn more than the vault owns.
            shares.sharesToBurn = Math.min(shares.sharesToBurn, _previouslyLockedShares + _newlyLockedShares);
            _burnShares(shares.sharesToBurn, address(this));

            // We burn first the newly locked shares, then the previously locked shares.
            uint256 sharesNotToLock = Math.min(shares.sharesToBurn, _newlyLockedShares);
            // Reduce the amounts to lock by how much we burned
            _newlyLockedShares -= sharesNotToLock;
            _previouslyLockedShares -= (shares.sharesToBurn - sharesNotToLock);
        }

        // Issue shares for fees that were calculated above if applicable.
        if (shares.accountantFeesShares > 0) {
            _issueShares(shares.accountantFeesShares, accountant);
        }

        if (shares.protocolFeesShares > 0) {
            _issueShares(shares.protocolFeesShares, fees.protocolFeeRecipient);
        }

        return (_previouslyLockedShares, _newlyLockedShares);
    }

    // Manage the unlocking of shares over time based on the vault's configuration.
    function _manageUnlockingOfShares(uint256 previouslyLockedShares, uint256 newlyLockedShares) internal {
        // Update unlocking rate and time to fully unlocked.
        uint256 totalLockedShares = previouslyLockedShares + newlyLockedShares;
        if (totalLockedShares > 0) {
            uint256 previouslyLockedTime = 0;
            // Check if we need to account for shares still unlocking.
            if (fullProfitUnlockDate > block.timestamp) {
                // There will only be previously locked shares if time remains.
                // We calculate this here since it will not occur every time we lock shares.
                previouslyLockedTime = previouslyLockedShares * (fullProfitUnlockDate - block.timestamp);
            }

            // newProfitLockingPeriod is a weighted average between the remaining time of the previously locked shares and the profitMaxUnlockTime
            uint256 newProfitLockingPeriod = (previouslyLockedTime + newlyLockedShares * profitMaxUnlockTime) / totalLockedShares;
            // Calculate how many shares unlock per second.
            profitUnlockingRate = totalLockedShares * MAX_BPS_EXTENDED / newProfitLockingPeriod;
            // Calculate how long until the full amount of shares is unlocked.
            fullProfitUnlockDate = block.timestamp + newProfitLockingPeriod;
            // Update the last profitable report timestamp.
            lastProfitUpdate = block.timestamp;
        } else {
            // NOTE: only setting this to 0 will turn in the desired effect, no need 
            // to update last_profit_update or full_profit_unlock_date
            profitUnlockingRate = 0;
        }
    }

    // SETTERS
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
        for (uint i = 0; i < newDefaultQueue.length; i++) {
            address strategy = newDefaultQueue[i];
            if (strategies[strategy].activation == 0) {
                revert InactiveStrategy();
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
    function setDepositLimit(uint256 _depositLimit) external override onlyRole(DEPOSIT_LIMIT_MANAGER) {
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
            _burnShares(_balanceOf[address(this)], address(this));
            // Reset unlocking variables to 0.
            profitUnlockingRate = 0;
            fullProfitUnlockDate = 0;
        }
        profitMaxUnlockTime = _newProfitMaxUnlockTime;
        emit UpdateProfitMaxUnlockTime(_newProfitMaxUnlockTime);
    }

    // ROLE MANAGEMENT

    // @notice Add a new role to an address.
    // @dev This will add a new role to the account
    //  without effecting any of the previously held roles.
    // @param account The account to add a role to.
    // @param role The new role to add to account.
    function addRole(address account, bytes32 role) public override onlyRole(ROLE_MANAGER) {
        _grantRole(role, account);
        emit RoleSet(account, role);
    }

    // @notice Remove a single role from an account.
    // @dev This will leave all other roles for the 
    //  account unchanged.
    // @param account The account to remove a Role from.
    // @param role The Role to remove.
    function removeRole(address account, bytes32 role) external override onlyRole(ROLE_MANAGER) {
        _revokeRole(role, account);
        emit RoleSet(account, role);
    }

    // @notice Set a role to be open.
    // @param role The role to set.
    function setOpenRole(bytes32 role) external override onlyRole(ROLE_MANAGER) {
        openRoles[role] = true;
        emit RoleStatusChanged(role, RoleStatusChange.OPENED);
    }

    // @notice Close a opened role.
    // @param role The role to close.
    function closeOpenRole(bytes32 role) external override onlyRole(ROLE_MANAGER) {
        openRoles[role] = false;
        emit RoleStatusChanged(role, RoleStatusChange.CLOSED);
    }

    // VAULT STATUS VIEWS

    // @notice Get the amount of shares that have been unlocked.
    // @return The amount of shares that are have been unlocked.
    function unlockedShares() external view override returns (uint256) {
        return _unlockedShares();
    }

    // @notice Get the price per share (pps) of the vault.
    // @dev This value offers limited precision. Integrations that require 
    //    exact precision should use convertToAssets or convertToShares instead.
    // @return The price per share.
    function pricePerShare() external view override returns (uint256) {
        return _convertToAssets(10**ISharesManager(sharesManager).decimals(), Rounding.ROUND_DOWN);
    }

    // REPORTING MANAGEMENT
    
    // @notice Process the report of a strategy.
    // @param strategy The strategy to process the report for.
    // @return The gain and loss of the strategy.
    function processReport(address strategy) external override onlyRole(REPORTING_MANAGER) nonReentrant returns (uint256, uint256) {
        return _processReport(strategy);
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
        uint256 shares = IERC20(strategy).balanceOf(address(this)) * amount / currentDebt;

        if (shares <= 0) {
            revert ZeroValue();
        }

        _erc20SafeTransferFrom(sharesManager, msg.sender, address(this), amount);

        // Lower strategy debt
        strategies[strategy].currentDebt -= amount;
        // lower total debt
        totalDebtAmount -= amount;
        // Increase total idle
        totalIdleAmount += amount;

        // Log debt change
        emit DebtUpdated(strategy, currentDebt, currentDebt - amount);

        // Transfer the strategies shares out
        _erc20SafeTransfer(strategy, msg.sender, shares);

        // Log the debt purchase
        emit DebtPurchased(strategy, amount);
    }

    // STRATEGY MANAGEMENT

    // @notice Add a new strategy.
    // @param new_strategy The new strategy to add.
    function addStrategy(address newStrategy) external override onlyRole(ADD_STRATEGY_MANAGER) {
        _addStrategy(newStrategy);
    }

    // @notice Revoke a strategy.
    // @param strategy The strategy to revoke.
    function revokeStrategy(address strategy) external override onlyRole(REVOKE_STRATEGY_MANAGER) {
        _revokeStrategy(strategy, false);
    }

    // @notice Force revoke a strategy.
    // @dev The vault will remove the strategy and write off any debt left 
    //    in it as a loss. This function is a dangerous function as it can force a 
    //    strategy to take a loss. All possible assets should be removed from the 
    //    strategy first via update_debt. If a strategy is removed erroneously it 
    //    can be re-added and the loss will be credited as profit. Fees will apply.
    // @param strategy The strategy to force revoke.
    function forceRevokeStrategy(address strategy) external override onlyRole(FORCE_REVOKE_MANAGER) {
        _revokeStrategy(strategy, true);
    }

    // DEBT MANAGEMENT

    // @notice Update the max debt for a strategy.
    // @param strategy The strategy to update the max debt for.
    // @param new_max_debt The new max debt for the strategy.
    function updateMaxDebtForStrategy(address strategy, uint256 newMaxDebt) external override onlyRole(MAX_DEBT_MANAGER) {
        // Delegate call to StrategyManager
        IStrategyManager(strategyManager).updateMaxDebtForStrategy(strategy, newMaxDebt);
    }

    // @notice Update the debt for a strategy.
    // @param strategy The strategy to update the debt for.
    // @param target_debt The target debt for the strategy.
    // @return The amount of debt added or removed.
    function updateDebt(address strategy, uint256 targetDebt) external override onlyRole(DEBT_MANAGER) nonReentrant returns (uint256) {
        return _updateDebt(strategy, targetDebt);
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

        addRole(msg.sender, DEBT_MANAGER);
        emit Shutdown();
    }

    // ## SHARE MANAGEMENT ##
    // ## ERC20 + ERC4626 ##

    // @notice Deposit assets into the vault.
    // @param assets The amount of assets to deposit.
    // @param receiver The address to receive the shares.
    // @return The amount of shares minted.
    function deposit(uint256 assets, address receiver) external override nonReentrant returns (uint256) {
        return ISharesManager(sharesManager).deposit(msg.sender, receiver, assets);
    }

    // @notice Mint shares for the receiver.
    // @param shares The amount of shares to mint.
    // @param receiver The address to receive the shares.
    // @return The amount of assets deposited.
    function mint(uint256 shares, address receiver) external override nonReentrant returns (uint256) {
        return ISharesManager(sharesManager).mint(msg.sender, receiver, shares);
    }

    // @notice Withdraw an amount of asset to `receiver` burning `owner`s shares.
    // @dev The default behavior is to not allow any loss.
    // @param assets The amount of asset to withdraw.
    // @param receiver The address to receive the assets.
    // @param owner The address who's shares are being burnt.
    // @param max_loss Optional amount of acceptable loss in Basis Points.
    // @param strategies Optional array of strategies to withdraw from.
    // @return The amount of shares actually burnt.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] memory _strategies
    ) external override nonReentrant returns (uint256) {
        return ISharesManager(sharesManager).withdraw(assets, receiver, owner, maxLoss, _strategies);
    }

    // @notice Redeems an amount of shares of `owners` shares sending funds to `receiver`.
    // @dev The default behavior is to allow losses to be realized.
    // @param shares The amount of shares to burn.
    // @param receiver The address to receive the assets.
    // @param owner The address who's shares are being burnt.
    // @param max_loss Optional amount of acceptable loss in Basis Points.
    // @param strategies Optional array of strategies to withdraw from.
    // @return The amount of assets actually withdrawn.
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] memory _strategies
    ) external override nonReentrant returns (uint256) {
        return ISharesManager(sharesManager).redeem(shares, receiver, owner, maxLoss, _strategies);
    }

    // @notice Approve an address to spend the vault's shares.
    // @param spender The address to approve.
    // @param amount The amount of shares to approve.
    // @return True if the approval was successful.
    function approve(address spender, uint256 amount) external override returns (bool) {
        return ISharesManager(sharesManager).approve(msg.sender, spender, amount);
    }

    // @notice Transfer shares to a receiver.
    // @param receiver The address to transfer shares to.
    // @param amount The amount of shares to transfer.
    // @return True if the transfer was successful.
    function transfer(address receiver, uint256 amount) external override returns (bool) {
        if (receiver == address(this) || receiver == address(0)) {
            revert ZeroAddress();
        }
        ISharesManager(sharesManager).transfer(msg.sender, receiver, amount);
        return true;
    }

    // @notice Transfer shares from a sender to a receiver.
    // @param sender The address to transfer shares from.
    // @param receiver The address to transfer shares to.
    // @param amount The amount of shares to transfer.
    // @return True if the transfer was successful.
    function transferFrom(address sender, address receiver, uint256 amount) external override returns (bool) {
        if (receiver == address(this) || receiver == address(0)) {
            revert ZeroAddress();
        }
        return ISharesManager(sharesManager).transferFrom(sender, receiver, amount);
    }

    // ## ERC20+4626 compatibility

    // @notice Increase the allowance for a spender.
    // @param spender The address to increase the allowance for.
    // @param amount The amount to increase the allowance by.
    // @return True if the increase was successful.
    function increaseAllowance(address spender, uint256 amount) external override returns (bool) {
        return _increaseAllowance(msg.sender, spender, amount);
    }

    // @notice Decrease the allowance for a spender.
    // @param spender The address to decrease the allowance for.
    // @param amount The amount to decrease the allowance by.
    // @return True if the decrease was successful.
    function decreaseAllowance(address spender, uint256 amount) external override returns (bool) {
        return _decreaseAllowance(msg.sender, spender, amount);
    }

    // @notice Approve an address to spend the vault's shares.
    // @param owner The address to approve.
    // @param spender The address to approve.
    // @param amount The amount of shares to approve.
    // @param deadline The deadline for the permit.
    // @param v The v component of the signature.
    // @param r The r component of the signature.
    // @param s The s component of the signature.
    // @return True if the approval was successful.
    function permit(
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override returns (bool) {
        return _permit(owner, spender, amount, deadline, v, r, s);
    }

    // @notice Get the balance of a user.
    // @param addr The address to get the balance of.
    // @return The balance of the user.
    function balanceOf(address addr) external view override returns (uint256) {
        return ISharesManager(sharesManager).balanceOf(addr);
    }

    // @notice Get the total supply of shares.
    // @return The total supply of shares.
    function totalSupply() external view override returns (uint256) {
        return _totalSupply();
    }

    // @notice Get the address of the asset.
    // @return The address of the asset.
    function asset() external view override returns (address) {
        return ISharesManager(sharesManager).asset();
    }

    // @notice Get the number of decimals of the asset/share.
    // @return The number of decimals of the asset/share.
    function decimals() external view override returns (uint8) {
        return ISharesManager(sharesManager).decimals();
    }

    // @notice Get the total assets held by the vault.
    // @return The total assets held by the vault.
    function totalAssets() external view override returns (uint256) {
        return ISharesManager(sharesManager).totalAssets();
    }

    // @notice Convert an amount of assets to shares.
    // @param assets The amount of assets to convert.
    // @return The amount of shares.
    function convertToShares(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, Rounding.ROUND_DOWN);
    }

    // @notice Preview the amount of shares that would be minted for a deposit.
    // @param assets The amount of assets to deposit.
    // @return The amount of shares that would be minted.
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, Rounding.ROUND_DOWN);
    }

    // @notice Preview the amount of assets that would be deposited for a mint.
    // @param shares The amount of shares to mint.
    // @return The amount of assets that would be deposited.
    function previewMint(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, Rounding.ROUND_UP);
    }

    // @notice Convert an amount of shares to assets.
    // @param shares The amount of shares to convert.
    // @return The amount of assets.
    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, Rounding.ROUND_DOWN);
    }

    // @notice Get the maximum amount of assets that can be deposited.
    // @param receiver The address that will receive the shares.
    // @return The maximum amount of assets that can be deposited.
    function maxDeposit(address receiver) external view override returns (uint256) {
        return _maxDeposit(receiver);
    }

    // @notice Get the maximum amount of shares that can be minted.
    // @param receiver The address that will receive the shares.
    // @return The maximum amount of shares that can be minted.
    function maxMint(address receiver) external view override returns (uint256) {
        return ISharesManager(sharesManager).maxMint(receiver);
    }

    // @notice Get the maximum amount of assets that can be withdrawn.
    // @dev Complies to normal 4626 interface and takes custom params.
    // @param owner The address that owns the shares.
    // @param max_loss Custom max_loss if any.
    // @param strategies Custom strategies queue if any.
    // @return The maximum amount of assets that can be withdrawn.
    function maxWithdraw(address owner, uint256 maxLoss, address[] memory _strategies) external override returns (uint256) {
        return _maxWithdraw(owner, maxLoss, _strategies);
    }

    // @notice Get the maximum amount of shares that can be redeemed.
    // @dev Complies to normal 4626 interface and takes custom params.
    // @param owner The address that owns the shares.
    // @param max_loss Custom max_loss if any.
    // @param strategies Custom strategies queue if any.
    // @return The maximum amount of shares that can be redeemed.
    function maxRedeem(address owner, uint256 maxLoss, address[] memory _strategies) external override returns (uint256) {
        return ISharesManager(sharesManager).maxRedeem(owner, maxLoss, _strategies);
    }

    // @notice Preview the amount of shares that would be redeemed for a withdraw.
    // @param assets The amount of assets to withdraw.
    // @return The amount of shares that would be redeemed.
    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, Rounding.ROUND_UP);
    }

    // @notice Preview the amount of assets that would be withdrawn for a redeem.
    // @param shares The amount of shares to redeem.
    // @return The amount of assets that would be withdrawn.
    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, Rounding.ROUND_DOWN);
    }

    // @notice Assess the share of unrealised losses that a strategy has.
    // @param strategy The address of the strategy.
    // @param assets_needed The amount of assets needed to be withdrawn.
    // @return The share of unrealised losses that the strategy has.
    function assessShareOfUnrealisedLosses(address strategy, uint256 assetsNeeded) external view override returns (uint256) {
        // Assuming strategies mapping and _assess_share_of_unrealised_losses are defined
        if (strategies[strategy].currentDebt < assetsNeeded) {
            revert StrategyDebtIsLessThanAssetsNeeded();
        }
        return _assessShareOfUnrealisedLosses(strategy, assetsNeeded);
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return ISharesManager(sharesManager).allowance(owner, spender);
    }

    // # eip-1344

    // EIP-712 domain separator
    function domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPE_HASH,
            keccak256("Yearn Vault"),
            keccak256(bytes(API_VERSION)),
            block.chainid,
            address(this)
        ));
    }
}
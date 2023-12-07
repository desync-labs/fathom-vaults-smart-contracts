// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.16;

import "./VaultStorage.sol";
import "./Interfaces/IVaultEvents.sol";
import "./Interfaces/IStrategyManager.sol";
import "./Interfaces/IStrategy.sol";
import "./Interfaces/ISharesManager.sol";
import "./Interfaces/IAccountant.sol";
import "./Interfaces/IFactory.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
@title STRATEGY MANAGEMENT
*/

contract StrategyManager is VaultStorage, IVaultEvents, IStrategyManager {
    // solhint-disable not-rely-on-time
    // solhint-disable var-name-mixedcase
    // solhint-disable function-max-lines
    // solhint-disable code-complexity
    // solhint-disable max-line-length
    // solhint-disable ordering

    using Math for uint256;

    // IMMUTABLE
    // Address of the underlying token used by the vault
    IERC20 public immutable ASSET;
    // Factory address
    address public immutable FACTORY;

    error ZeroAddress();
    error InactiveStrategy();
    error InvalidAsset();
    error StrategyAlreadyActive();
    error StrategyHasDebt();
    error DebtDidntChange();
    error ZeroValue();
    error StrategyHasUnrealisedLosses();
    error DebtHigherThanMaxDebt();
    error InsufficientFunds();
    error StrategyDebtIsLessThanAssetsNeeded();


    constructor(
        address _asset,
        address _sharesManager
    ) {
        ASSET = IERC20(_asset);
        FACTORY = msg.sender;
        sharesManager = _sharesManager;
    }


    function addStrategy(address newStrategy) external override {
        if (newStrategy == address(0) || newStrategy == address(this)) {
            revert ZeroAddress();
        }
        if (IStrategy(newStrategy).asset() != address(ASSET)) {
            revert InvalidAsset();
        }
        if (strategies[newStrategy].activation != 0) {
            revert StrategyAlreadyActive();
        }

        // Add the new strategy to the mapping.
        strategies[newStrategy] = StrategyParams({
            activation: block.timestamp,
            lastReport: block.timestamp,
            currentDebt: 0,
            maxDebt: 0
        });

        // If the default queue has space, add the strategy.
        uint256 defaultQueueLength = defaultQueue.length;
        if (defaultQueueLength < MAX_QUEUE) {
            defaultQueue.push(newStrategy);
        }
        
        emit StrategyChanged(newStrategy, StrategyChangeType.ADDED);
    }

    function revokeStrategy(address strategy, bool force) external override {
        if (strategies[strategy].activation == 0) {
            revert InactiveStrategy();
        }
        
        // If force revoking a strategy, it will cause a loss.
        uint256 loss = 0;
        if (strategies[strategy].currentDebt != 0 && !force) {
            revert StrategyHasDebt();
        }

        // Vault realizes the full loss of outstanding debt.
        loss = strategies[strategy].currentDebt;
        // Adjust total vault debt.
        totalDebtAmount -= loss;
        
        emit StrategyReported(strategy, 0, loss, 0, 0, 0, 0);

        // Set strategy params all back to 0 (WARNING: it can be re-added).
        strategies[strategy] = StrategyParams({
            activation: 0,
            lastReport: 0,
            currentDebt: 0,
            maxDebt: 0
        });

        // Remove strategy if it is in the default queue.
        address[] memory newQueue;
        if (defaultQueue.length > 0) {
            for (uint256 i = 0; i < defaultQueue.length; i++) {
                address _strategy = defaultQueue[i];
                // Add all strategies to the new queue besides the one revoked.
                if (_strategy != strategy) {
                    newQueue[i] = _strategy;
                }
            }
        }

        // Set the default queue to our updated queue.
        defaultQueue = newQueue;

        emit StrategyChanged(strategy, StrategyChangeType.REVOKED);
    }

    function updateMaxDebtForStrategy(address strategy, uint256 newMaxDebt) external override {
        if (strategies[strategy].activation == 0) {
            revert InactiveStrategy();
        }
        strategies[strategy].maxDebt = newMaxDebt;
        emit UpdatedMaxDebtForStrategy(tx.origin, strategy, newMaxDebt);
    }

    function updateDebt(address sender, address strategy, uint256 targetDebt) external override returns (uint256) {
        totalIdleAmount = ISharesManager(sharesManager).getTotalIdleAmount();
        minimumTotalIdle = ISharesManager(sharesManager).getMinimumTotalIdle();
        if (strategies[strategy].currentDebt != targetDebt && totalIdleAmount <= minimumTotalIdle) {
            revert InsufficientFunds();
        }
        
        // How much we want the strategy to have.
        uint256 newDebt = targetDebt;
        // How much the strategy currently has.
        uint256 currentDebt = strategies[strategy].currentDebt;

        // If the vault is shutdown we can only pull funds.
        if (shutdown == true) {
            newDebt = 0;
        }

        if (newDebt == currentDebt) {
            revert DebtDidntChange();
        }

        if (currentDebt > newDebt) {
            // Reduce debt
            uint256 assetsToWithdraw = currentDebt - newDebt;

            // Respect minimum total idle in vault
            if (totalIdleAmount + assetsToWithdraw < minimumTotalIdle) {
                assetsToWithdraw = minimumTotalIdle - totalIdleAmount;
                // Cant withdraw more than the strategy has.
                if (assetsToWithdraw > currentDebt) {
                    assetsToWithdraw = currentDebt;
                }
            }

            // Check how much we are able to withdraw.
            // Use maxRedeem and convert since we use redeem.
            uint256 withdrawable = IStrategy(strategy).convertToAssets(IStrategy(strategy).maxRedeem(sender));

            if (withdrawable <= 0) {
                revert ZeroValue();
            }

            // If insufficient withdrawable, withdraw what we can.
            if (withdrawable < assetsToWithdraw) {
                assetsToWithdraw = withdrawable;
            }

            // If there are unrealised losses we don't let the vault reduce its debt until there is a new report
            uint256 unrealisedLossesShare = ISharesManager(sharesManager).assessShareOfUnrealisedLosses(strategy, assetsToWithdraw);
            if (unrealisedLossesShare != 0) {
                revert StrategyHasUnrealisedLosses();
            }

            // Always check the actual amount withdrawn.
            uint256 preBalance = ASSET.balanceOf(sender);
            ISharesManager(sharesManager).withdrawFromStrategy(strategy, assetsToWithdraw);
            uint256 postBalance = ASSET.balanceOf(sender);

            // making sure we are changing idle according to the real result no matter what. 
            // We pull funds with {redeem} so there can be losses or rounding differences.
            uint256 withdrawn = Math.min(postBalance - preBalance, currentDebt);

            // If we got too much make sure not to increase PPS.
            if (withdrawn > assetsToWithdraw) {
                assetsToWithdraw = withdrawn;
            }

            // Update storage.
            totalIdleAmount += withdrawn; // actual amount we got.
            // Amount we tried to withdraw in case of losses
            totalDebtAmount -= assetsToWithdraw;

            ISharesManager(sharesManager).setTotalIdleAmount(totalIdleAmount);
            ISharesManager(sharesManager).setTotalDebtAmount(totalDebtAmount);

            newDebt = currentDebt - assetsToWithdraw;
        } else {
            // We are increasing the strategies debt

            // Revert if target_debt cannot be achieved due to configured max_debt for given strategy
            if (newDebt > strategies[strategy].maxDebt) {
                revert DebtHigherThanMaxDebt();
            }

            // Vault is increasing debt with the strategy by sending more funds.
            uint256 currentMaxDeposit = IStrategy(strategy).maxDeposit(sender);
            if (currentMaxDeposit <= 0) {
                revert ZeroValue();
            }

            // Deposit the difference between desired and current.
            uint256 assetsToDeposit = newDebt - currentDebt;
            if (assetsToDeposit > currentMaxDeposit) {
                // Deposit as much as possible.
                assetsToDeposit = currentMaxDeposit;
            }

            uint256 availableIdle = totalIdleAmount - minimumTotalIdle;

            // If insufficient funds to deposit, transfer only what is free.
            if (assetsToDeposit > availableIdle) {
                assetsToDeposit = availableIdle;
            }

            // Can't Deposit 0.
            if (assetsToDeposit > 0) {
                // Approve the strategy to pull only what we are giving it.
                ISharesManager(sharesManager).erc20SafeApprove(address(ASSET), strategy, assetsToDeposit);

                // Always update based on actual amounts deposited.
                uint256 preBalance = ASSET.balanceOf(sharesManager);
                ISharesManager(sharesManager).depositToStrategy(strategy, assetsToDeposit);
                uint256 postBalance = ASSET.balanceOf(sharesManager);

                // Make sure our approval is always back to 0.
                ISharesManager(sharesManager).erc20SafeApprove(address(ASSET), strategy, 0);

                // Making sure we are changing according to the real result no 
                // matter what. This will spend more gas but makes it more robust.
                assetsToDeposit = preBalance - postBalance;

                // Update storage.
                totalIdleAmount -= assetsToDeposit;
                totalDebtAmount += assetsToDeposit;

                ISharesManager(sharesManager).setTotalIdleAmount(totalIdleAmount);
                ISharesManager(sharesManager).setTotalDebtAmount(totalDebtAmount);

                newDebt = currentDebt + assetsToDeposit;
            }
        }

        // Commit memory to storage.
        strategies[strategy].currentDebt = newDebt;

        emit DebtUpdated(strategy, currentDebt, newDebt);
        return newDebt;
    }

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
    function processReport(address strategy) external override returns (uint256, uint256) {
        // Make sure we have a valid strategy.
        if (strategies[strategy].activation == 0) {
            revert InactiveStrategy();
        }

        // Burn shares that have been unlocked since the last update
        ISharesManager(sharesManager).burnUnlockedShares();

        (uint256 gain, uint256 loss) = _assessProfitAndLoss(strategy);

        FeeAssessment memory fees = _assessFees(strategy, gain, loss);

        ShareManagement memory shares = ISharesManager(sharesManager).calculateShareManagement(loss, fees.totalFees, fees.protocolFees);

        (uint256 previouslyLockedShares, uint256 newlyLockedShares) = ISharesManager(sharesManager).handleShareBurnsAndIssues(shares, fees, gain, loss, strategy);

        ISharesManager(sharesManager).manageUnlockingOfShares(previouslyLockedShares, newlyLockedShares);

        // Record the report of profit timestamp.
        strategies[strategy].lastReport = block.timestamp;

        // We have to recalculate the fees paid for cases with an overall loss.
        emit StrategyReported(
            strategy,
            gain,
            loss,
            strategies[strategy].currentDebt,
            ISharesManager(sharesManager).convertToAssets(shares.protocolFeesShares, Rounding.ROUND_DOWN),
            ISharesManager(sharesManager).convertToAssets(shares.protocolFeesShares + shares.accountantFeesShares, Rounding.ROUND_DOWN),
            fees.totalRefunds
        );

        return (gain, loss);
    }

    // Assess the profit and loss of a strategy.
    function _assessProfitAndLoss(address strategy) internal view returns (uint256 gain, uint256 loss) {
        // Vault assesses profits using 4626 compliant interface.
        // NOTE: It is important that a strategies `convertToAssets` implementation
        // cannot be manipulated or else the vault could report incorrect gains/losses.
        uint256 strategyShares = IStrategy(strategy).balanceOf(sharesManager);
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

    // Used only to approve tokens that are not the type managed by this Vault.
    // Used to handle non-compliant tokens like USDT
    function erc20SafeApprove(address token, address spender, uint256 amount) internal {
        if (token == address(0) || spender == address(0)) {
            revert ZeroAddress();
        }
        require(IERC20(token).approve(spender, amount), "approval failed");
    }
}
    
// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.16;

import "./VaultStorage.sol";
import "./Interfaces/IVaultEvents.sol";
import "./Interfaces/IStrategyManager.sol";
import "./Interfaces/IStrategy.sol";
import "./Interfaces/ISharesManager.sol";
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

    using Math for uint256;

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

    // IMMUTABLE
    // Address of the underlying token used by the vault
    IERC20 public immutable ASSET;

    constructor(
        address _asset
    ) {
        ASSET = IERC20(_asset);
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
            for (uint i = 0; i < defaultQueue.length; i++) {
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
        emit UpdatedMaxDebtForStrategy(msg.sender, strategy, newMaxDebt);
    }

    function updateDebt(address strategy, uint256 targetDebt, address sharesManager) external override returns (uint256) {
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
            uint256 withdrawable = IStrategy(strategy).convertToAssets(IStrategy(strategy).maxRedeem(address(this)));

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
            uint256 preBalance = ASSET.balanceOf(address(this));
            ISharesManager(sharesManager).withdrawFromStrategy(strategy, assetsToWithdraw);
            uint256 postBalance = ASSET.balanceOf(address(this));

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

            newDebt = currentDebt - assetsToWithdraw;
        } else {
            // We are increasing the strategies debt

            // Revert if target_debt cannot be achieved due to configured max_debt for given strategy
            if (newDebt > strategies[strategy].maxDebt) {
                revert DebtHigherThanMaxDebt();
            }

            // Vault is increasing debt with the strategy by sending more funds.
            uint256 currentMaxDeposit = IStrategy(strategy).maxDeposit(address(this));
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
                _erc20SafeApprove(address(ASSET), strategy, assetsToDeposit);

                // Always update based on actual amounts deposited.
                uint256 preBalance = ASSET.balanceOf(address(this));
                IStrategy(strategy).deposit(assetsToDeposit, address(this));
                uint256 postBalance = ASSET.balanceOf(address(this));

                // Make sure our approval is always back to 0.
                _erc20SafeApprove(address(ASSET), strategy, 0);

                // Making sure we are changing according to the real result no 
                // matter what. This will spend more gas but makes it more robust.
                assetsToDeposit = preBalance - postBalance;

                // Update storage.
                totalIdleAmount -= assetsToDeposit;
                totalDebtAmount += assetsToDeposit;

                newDebt = currentDebt + assetsToDeposit;
            }
        }

        // Commit memory to storage.
        strategies[strategy].currentDebt = newDebt;

        emit DebtUpdated(strategy, currentDebt, newDebt);
        return newDebt;
    }

    function _erc20SafeApprove(address token, address spender, uint256 amount) internal {
        if (token == address(0) || spender == address(0)) {
            revert ZeroAddress();
        }
        require(IERC20(token).approve(spender, amount), "approval failed");
    }
}
    
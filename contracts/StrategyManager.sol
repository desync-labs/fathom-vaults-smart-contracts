// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.16;

import "./VaultStorage.sol";
import "./Interfaces/IVaultEvents.sol";
import "./Interfaces/IStrategyManager.sol";
import "./Interfaces/IStrategy.sol";

/**
@title STRATEGY MANAGEMENT
*/

contract StrategyManager is VaultStorage, IVaultEvents, IStrategyManager {
    // solhint-disable not-rely-on-time
    // solhint-disable var-name-mixedcase

    error ZeroAddress();
    error InactiveStrategy();
    error InvalidAsset();
    error StrategyAlreadyActive();
    error StrategyHasDebt();

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
}
    
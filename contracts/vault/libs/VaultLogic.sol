// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

import "../VaultErrors.sol";
import { FeeAssessment, ReportInfo, Rounding, ShareManagement } from "../VaultStructs.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IStrategy } from "../../strategy/interfaces/IStrategy.sol";
import { IVault } from "../interfaces/IVault.sol";
import { IFactory } from "../../factory/interfaces/IFactory.sol";
import { IAccountant } from "../../accountant/interfaces/IAccountant.sol";

library VaultLogic {
    uint256 public constant MAX_BPS = 10000;

    function increaseDebt(
        address strategy,
        uint256 strategyMaxDebt,
        uint256 newDebt,
        uint256 currentDebt,
        uint256 currentTotalIdle,
        uint256 minimumTotalIdle
    ) external view returns (uint256 assetsToDeposit) {
        // Revert if target_debt cannot be achieved due to configured max_debt for given strategy
        if (newDebt > strategyMaxDebt) {
            revert DebtHigherThanMaxDebt(newDebt, strategyMaxDebt);
        }

        // Vault is increasing debt with the strategy by sending more funds.
        uint256 currentMaxDeposit = IStrategy(strategy).maxDeposit(address(this));
        if (currentMaxDeposit == 0) {
            revert ZeroValue();
        }

        // Deposit the difference between desired and current.
        assetsToDeposit = newDebt - currentDebt;
        if (assetsToDeposit > currentMaxDeposit) {
            // Deposit as much as possible.
            assetsToDeposit = currentMaxDeposit;
        }

        // Ensure we always have minimumTotalIdle when updating debt.
        if (currentTotalIdle <= minimumTotalIdle) {
            revert InsufficientFunds();
        }

        uint256 availableIdle = currentTotalIdle - minimumTotalIdle;

        // If insufficient funds to deposit, transfer only what is free.
        if (assetsToDeposit > availableIdle) {
            assetsToDeposit = availableIdle;
        }
    }

    function decreaseDebt(
        address strategy,
        uint256 newDebt,
        uint256 currentDebt,
        uint256 totalIdle,
        uint256 minimumTotalIdle,
        IERC20 asset
    ) external returns (uint256 withdrawn, uint256 assetsToWithdraw) {
        assetsToWithdraw = currentDebt - newDebt;

        // Respect minimum total idle in vault
        if (totalIdle + assetsToWithdraw < minimumTotalIdle) {
            assetsToWithdraw = minimumTotalIdle - totalIdle;
            // Cant withdraw more than the strategy has.
            if (assetsToWithdraw > currentDebt) {
                assetsToWithdraw = currentDebt;
            }
        }

        // Check how much we are able to withdraw.n
        // Use maxRedeem and convert since we use redeem.
        uint256 withdrawable = IStrategy(strategy).convertToAssets(IStrategy(strategy).maxRedeem(address(this)));

        if (withdrawable == 0) {
            revert ZeroValue();
        }

        // If insufficient withdrawable, withdraw what we can.
        if (withdrawable < assetsToWithdraw) {
            assetsToWithdraw = withdrawable;
        }

        // If there are unrealised losses we don't let the vault reduce its debt until there is a new report
        uint256 unrealisedLossesShare = assessShareOfUnrealisedLosses(strategy, assetsToWithdraw, currentDebt);
        if (unrealisedLossesShare != 0) {
            revert StrategyHasUnrealisedLosses(unrealisedLossesShare);
        }

        // Always check the actual amount withdrawn.
        uint256 preBalance = asset.balanceOf(address(this));
        withdrawFromStrategy(strategy, assetsToWithdraw);
        uint256 postBalance = asset.balanceOf(address(this));

        // making sure we are changing idle according to the real result no matter what.
        // We pull funds with {redeem} so there can be losses or rounding differences.
        withdrawn = Math.min(postBalance - preBalance, currentDebt);

        // If we got too much make sure not to increase PPS.
        if (withdrawn > assetsToWithdraw) {
            assetsToWithdraw = withdrawn;
        }
    }

    function withdrawFromStrategy(address strategy, uint256 assetsToWithdraw) public {
        // Need to get shares since we use redeem to be able to take on losses.
        uint256 sharesToRedeem = Math.min(
            IStrategy(strategy).previewWithdraw(assetsToWithdraw), // Use previewWithdraw since it should round up.
            IStrategy(strategy).balanceOf(address(this)) // And check against our actual balance.
        );

        // Redeem the shares.
        IStrategy(strategy).redeem(sharesToRedeem, address(this), address(this));
    }

    function assessShareOfUnrealisedLosses(address strategy, uint256 assetsNeeded, uint256 strategyCurrentDebt) public view returns (uint256) {
        // The actual amount that the debt is currently worth.
        uint256 vaultShares = IStrategy(strategy).balanceOf(address(this));
        uint256 strategyAssets = IStrategy(strategy).convertToAssets(vaultShares);

        // If no losses, return 0
        if (strategyAssets >= strategyCurrentDebt || strategyCurrentDebt == 0) {
            return 0;
        }

        // Users will withdraw assets_to_withdraw divided by loss ratio (strategyAssets / strategyCurrentDebt - 1),
        // but will only receive assets_to_withdraw.
        // NOTE: If there are unrealised losses, the user will take his share.
        uint256 numerator = assetsNeeded * strategyAssets;
        uint256 lossesUserShare = assetsNeeded - numerator / strategyCurrentDebt;

        return lossesUserShare;
    }

    function assessProfitAndLoss(address strategy, uint256 currentDebt) public view returns (uint256 gain, uint256 loss) {
        // Vault assesses profits using 4626 compliant interface.
        // NOTE: It is important that a strategies `convertToAssets` implementation
        // cannot be manipulated or else the vault could report incorrect gains/losses.
        uint256 strategyShares = IStrategy(strategy).balanceOf(address(this));
        // How much the vaults position is worth.
        uint256 currentTotalAssets = IStrategy(strategy).convertToAssets(strategyShares);

        uint256 _gain;
        uint256 _loss;

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

    function assessFees(address strategy, uint256 gain, uint256 loss, address accountant, address factory) public returns (FeeAssessment memory) {
        FeeAssessment memory fees = FeeAssessment(0, 0, 0, address(0));

        if (accountant != address(0x00)) {
            (fees.totalFees, fees.totalRefunds) = IAccountant(accountant).report(strategy, gain, loss);
            // Protocol fees will be 0 if accountant fees are 0.
            if (fees.totalFees > 0) {
                uint16 protocolFeeBps;
                // Get the config for this vault.
                (protocolFeeBps, fees.protocolFeeRecipient) = IFactory(factory).protocolFeeConfig();

                if (protocolFeeBps > 0) {
                    if (protocolFeeBps > MAX_BPS) {
                        revert FeeExceedsMax();
                    }
                    // Protocol fees are a percent of the fees the accountant is charging.
                    fees.protocolFees = (fees.totalFees * uint256(protocolFeeBps)) / MAX_BPS;
                }
            }
        }

        return fees;
    }

    function processReport(
        address strategy,
        uint256 currentDebt,
        uint256 totalSupply,
        uint256 totalAssets,
        address accountant,
        address factory
    ) external returns (ReportInfo memory) {
        (uint256 gain, uint256 loss) = assessProfitAndLoss(strategy, currentDebt);

        FeeAssessment memory assessmentFees = assessFees(strategy, gain, loss, accountant, factory);

        ShareManagement memory shares = calculateShareManagement(
            loss,
            assessmentFees.totalFees,
            assessmentFees.protocolFees,
            totalSupply,
            totalAssets
        );

        return ReportInfo(gain, loss, assessmentFees.protocolFees, assessmentFees.totalFees, assessmentFees, shares);
    }

    /// @notice Calculate share management based on gains, losses, and fees.
    function calculateShareManagement(
        uint256 loss,
        uint256 totalFees,
        uint256 protocolFees,
        uint256 totalSupply,
        uint256 totalAssets
    ) public pure returns (ShareManagement memory) {
        // `shares_to_burn` is derived from amounts that would reduce the vaults PPS.
        // NOTE: this needs to be done before any pps changes
        ShareManagement memory shares;

        // Only need to burn shares if there is a loss or fees.
        if (loss + totalFees > 0) {
            // The amount of shares we will want to burn to offset losses and fees.
            shares.sharesToBurn = _convertToShares(loss + totalFees, totalSupply, totalAssets, Rounding.ROUND_UP);

            // Vault calculates the amount of shares to mint as fees before changing totalAssets / totalSupply.
            if (totalFees > 0) {
                // Accountant fees are total fees - protocol fees.
                shares.accountantFeesShares = _convertToShares(totalFees - protocolFees, totalSupply, totalAssets, Rounding.ROUND_DOWN);
                if (protocolFees > 0) {
                    shares.protocolFeesShares = _convertToShares(protocolFees, totalSupply, totalAssets, Rounding.ROUND_DOWN);
                }
            }
        }

        return shares;
    }

    function convertToAssets(uint256 shares, uint256 totalSupply, uint256 totalAssets, Rounding rounding) public pure returns (uint256) {
        if (shares == type(uint256).max || shares == 0) {
            return shares;
        }

        // if totalSupply is 0, pricePerShare is 1
        if (totalSupply == 0) {
            return shares;
        }

        uint256 numerator = shares * totalAssets;
        uint256 amount = numerator / totalSupply;
        if (rounding == Rounding.ROUND_UP && numerator % totalSupply != 0) {
            amount += 1;
        }

        return amount;
    }

    /// @notice Validates the state and inputs for the redeem operation.
    function validateRedeem(address receiver, uint256 sharesToBurn, uint256 maxLoss, uint256 maxBPS, uint256 userSharesBalance) external pure {
        if (receiver == address(0)) {
            revert ZeroAddress();
        }
        if (maxLoss > maxBPS) {
            revert MaxLoss();
        }
        if (sharesToBurn == 0) {
            revert ZeroValue();
        }
        if (userSharesBalance < sharesToBurn) {
            revert InsufficientShares(userSharesBalance);
        }
    }

    function convertToShares(
        uint256 assets,
        uint256 currentTotalSupply,
        uint256 currentTotalAssets,
        Rounding rounding
    ) external pure returns (uint256) {
        return _convertToShares(assets, currentTotalSupply, currentTotalAssets, rounding);
    }

    function _convertToShares(
        uint256 assets,
        uint256 currentTotalSupply,
        uint256 currentTotalAssets,
        Rounding rounding
    ) internal pure returns (uint256) {
        if (assets == type(uint256).max || assets == 0) {
            return assets;
        }

        if (currentTotalAssets == 0) {
            // if totalAssets and totalSupply is 0, pricePerShare is 1
            if (currentTotalSupply == 0) {
                return assets;
            } else {
                // Else if totalSupply > 0 pricePerShare is 0
                return 0;
            }
        }

        uint256 numerator = assets * currentTotalSupply;
        uint256 shares = numerator / currentTotalAssets;
        if (rounding == Rounding.ROUND_UP && numerator % currentTotalAssets != 0) {
            shares += 1;
        }

        return shares;
    }
}

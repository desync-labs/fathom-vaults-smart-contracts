// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

import "../BaseStrategy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ITradeFintechStrategy } from "./ITradeFintechStrategy.sol";

// solhint-disable
contract TradeFintechStrategy is BaseStrategy, ITradeFintechStrategy {
    using SafeERC20 for ERC20;
    using Math for uint256;

    uint256 public totalInvested;
    uint256 public depositLimit;

    // Define periods
    uint256 public depositPeriodEnds;
    uint256 public lockPeriodEnds;

    constructor(
        address asset,
        string memory name,
        address tokenizedStrategyAddress,
        uint256 depositEndTS,
        uint256 lockedEndTS,
        uint256 maxDeposit
    ) BaseStrategy(asset, name, tokenizedStrategyAddress) {
        if (depositEndTS < block.timestamp || lockedEndTS < block.timestamp) {
            revert InvalidPeriods();
        }
        depositPeriodEnds = depositEndTS;
        lockPeriodEnds = lockedEndTS;
        depositLimit = maxDeposit;
    }

    /// @inheritdoc ITradeFintechStrategy
    function reportGain(uint256 amount) external override onlyManagement {
        if (amount == 0) revert ZeroAmount();
        totalInvested += amount;
        emit GainReported(msg.sender, amount);
    }

    /// @inheritdoc ITradeFintechStrategy
    function reportLoss(uint256 amount) external override onlyManagement {
        if (amount == 0) revert ZeroAmount();
        if (amount > totalInvested) revert InvalidLossAmount(amount, totalInvested);

        totalInvested -= amount;
        emit LossReported(msg.sender, amount);
    }

    /// @inheritdoc ITradeFintechStrategy
    function returnFunds(uint256 amount) external override onlyManagement {
        if (amount == 0) revert ZeroAmount();
        // Transfer the amount from the manager to the strategy contract
        _freeFunds(amount);
        emit FundsReturned(msg.sender, amount);
    }

    /// @inheritdoc ITradeFintechStrategy
    function lockFunds(uint256 amount) external override onlyManagement {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp > depositPeriodEnds) revert LockPeriodEnded();

        _deployFunds(amount);
        emit FundsLocked(msg.sender, amount);
    }

    /// @inheritdoc ITradeFintechStrategy
    function setDepositLimit(uint256 limit) external override onlyManagement {
        uint256 invested = totalInvested;
        if (limit == 0 || limit < invested) revert InvalidDepositLimit(limit, invested);

        depositLimit = limit;
        emit DepositLimitSet(msg.sender, limit);
    }

    /// @inheritdoc BaseStrategy
    /// @notice if the deposit period has ended, the deposit limit is 0
    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        return block.timestamp > depositPeriodEnds ? 0 : depositLimit - totalInvested;
    }

    /// @inheritdoc BaseStrategy
    /// @notice if the lock period hasn't ended, the withdraw limit is 0
    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        return block.timestamp > lockPeriodEnds ? asset.balanceOf(address(this)) + totalInvested : 0;
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        _totalAssets = totalInvested + asset.balanceOf(address(this));
    }

    /// @inheritdoc BaseStrategy
    function _deployFunds(uint256 amount) internal override {
        uint256 balance = asset.balanceOf(address(this));
        if (amount > balance) {
            revert InsufficientFundsIdle(amount, balance);
        }

        asset.transfer(TokenizedStrategy.management(), amount);
        totalInvested += amount;
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(uint256 amount) internal override {
        uint256 invested = totalInvested;
        if (amount > invested) revert InsufficientFundsLocked(amount, invested);

        address manager = TokenizedStrategy.management();
        uint256 managerBalance = asset.balanceOf(manager);

        if (amount > managerBalance) {
            revert ManagerBalanceTooLow(managerBalance, amount);
        }

        asset.safeTransferFrom(manager, address(this), amount);
        totalInvested -= amount;
    }

    function _emergencyWithdraw(uint256 amount) internal override {
        uint256 locked = totalInvested;
        if (amount > locked) revert InsufficientFundsLocked(amount, locked);

        address manager = TokenizedStrategy.management();
        uint256 amountToTransfer = Math.min(amount, asset.balanceOf(manager));

        asset.safeTransferFrom(manager, address(this), amountToTransfer);
        totalInvested -= amountToTransfer;
    }
}

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
        address _asset,
        string memory _name,
        address _tokenizedStrategyAddress,
        uint256 _depositPeriodEnds,
        uint256 _lockPeriodEnds,
        uint256 _depositLimit
    ) BaseStrategy(_asset, _name, _tokenizedStrategyAddress) {
        if (_depositPeriodEnds < block.timestamp || _lockPeriodEnds < block.timestamp) {
            revert InvalidPeriods();
        }
        depositPeriodEnds = _depositPeriodEnds;
        lockPeriodEnds = _lockPeriodEnds;
        depositLimit = _depositLimit;
    }

    /// @inheritdoc ITradeFintechStrategy
    function reportGainOrLoss(uint256 _amount, bool _isGain) external onlyManagement {
        if (_isGain) {
            totalInvested += _amount;
            emit GainReported(msg.sender, _amount);
        } else {
            if (_amount > totalInvested) revert InvalidLossAmount(_amount, totalInvested);
            totalInvested -= _amount;
            emit LossReported(msg.sender, _amount);
        }
    }

    /// @inheritdoc ITradeFintechStrategy
    function returnFunds(uint256 amount) external onlyManagement {
        // Transfer the amount from the manager to the strategy contract
        _freeFunds(amount);
        emit FundsReturned(msg.sender, amount);
    }

    /// @inheritdoc ITradeFintechStrategy
    function lockFunds(uint256 amount) external onlyManagement {
        _deployFunds(amount);
        emit FundsLocked(msg.sender, amount);
    }

    /// @inheritdoc ITradeFintechStrategy
    function setDepositLimit(uint256 limit) external onlyManagement {
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
        if (amount == 0) revert ZeroValue();
        if (amount > availableDepositLimit(address(0))) revert InsufficientFunds();

        asset.transfer(TokenizedStrategy.management(), amount);
        totalInvested += amount;
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(uint256 amount) internal override {
        uint256 invested = totalInvested;

        if (amount == 0) revert ZeroValue();
        if (amount > invested) revert InsufficientFunds();

        address manager = TokenizedStrategy.management();
        uint256 managerBalance = asset.balanceOf(manager);

        if (amount > managerBalance || amount > invested) {
            revert ManagerBalanceTooLow(managerBalance, amount, invested);
        }

        asset.safeTransferFrom(manager, address(this), amount);
        totalInvested -= amount;
    }

    /// @inheritdoc BaseStrategy
    function _emergencyWithdraw(uint256 _amount) internal override {
        address manager = TokenizedStrategy.management();
        uint256 balance = asset.balanceOf(address(this));
        uint256 amountToTransfer;

        if (_amount > balance) {
             // we cannot withdraw from manager more than the total invested
            uint256 availableManagerBalance = Math.min(asset.balanceOf(manager), totalInvested);
            uint256 amountToWithdraw = Math.min(_amount - balance, availableManagerBalance);
            _freeFunds(amountToWithdraw);

            amountToTransfer = asset.balanceOf(address(this));
        } else {
            amountToTransfer = _amount;
        }

        asset.transfer(manager, amountToTransfer);
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseStrategy} from "../../strategy/BaseStrategy.sol";
import { ITradeFintechStrategy } from "../../strategy/trade-fintech/ITradeFintechStrategy.sol";

interface ITradeFintechStrategyMock is ITradeFintechStrategy {
    function startDepositPeriod() external;
    function startLockPeriod() external;
    function endLockPeriod() external;
}

// solhint-disable
contract TradeFintechStrategyMock is BaseStrategy, ITradeFintechStrategyMock {
 using SafeERC20 for ERC20;
    using Math for uint256;

    uint256 public totalInvested;
    uint256 public depositLimit;

    uint256 public depositPeriodEnds;
    uint256 public lockPeriodEnds;
    address public immutable vault;

    constructor(
        address asset,
        string memory name,
        address tokenizedStrategyAddress,
        uint256 depositEndTS,
        uint256 lockedEndTS,
        uint256 maxDeposit,
        address vaultAddr
    ) BaseStrategy(asset, name, tokenizedStrategyAddress) {
        if (depositEndTS < block.timestamp || lockedEndTS < block.timestamp || depositEndTS > lockedEndTS) {
            revert InvalidPeriods();
        }
        depositPeriodEnds = depositEndTS;
        lockPeriodEnds = lockedEndTS;
        depositLimit = maxDeposit;
        vault = vaultAddr;
    }

    /// @inheritdoc ITradeFintechStrategy
    function repay(uint256 amount) external override onlyManagement {
        if (totalInvested == 0) revert FundsAlreadyReturned();
        if (amount == 0) revert ZeroAmount();

        if (amount > totalInvested) {
            emit GainReported(msg.sender, amount - totalInvested);
        } else {
            emit LossReported(msg.sender, totalInvested - amount);
        }
        // Transfer the amount from the manager to the strategy contract
        asset.safeTransferFrom(msg.sender, address(this), amount);
        totalInvested = 0;

        emit FundsReturned(msg.sender, amount);
    }

    /// @inheritdoc ITradeFintechStrategy
    function lockFunds(uint256 amount) external override onlyManagement {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp > lockPeriodEnds) revert LockPeriodEnded();

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

    function startDepositPeriod() external {
        depositPeriodEnds = block.timestamp + 1000 days;
        lockPeriodEnds = block.timestamp + 1001 days;
    }

    function startLockPeriod() external {
        depositPeriodEnds = block.timestamp - 1;
        lockPeriodEnds = block.timestamp + 1000 days;
    }

    function endLockPeriod() external {
        depositPeriodEnds = block.timestamp - 2;
        lockPeriodEnds = block.timestamp - 1;
    }

    /// @inheritdoc BaseStrategy
    /// @notice if the deposit period has ended, the deposit limit is 0
    function availableDepositLimit(address owner) public view override returns (uint256) {
        if (owner != vault && block.timestamp > depositPeriodEnds) return 0;
        return depositLimit - _getTotalAssets();
    }

    /// @inheritdoc BaseStrategy
    /// @notice if the lock period hasn't ended, the withdraw limit is 0
    function availableWithdrawLimit(address) public view override returns (uint256) {
        // if deposit period hasn't ended, we can withdraw everything incuding deployed funds
        if (block.timestamp < depositPeriodEnds) return _getTotalAssets();
        // if lock period hasn't ended, we can't withdraw anything
        if (block.timestamp < lockPeriodEnds) return 0;
        // if lock period has ended, we can withdraw from repaid funds
        return asset.balanceOf(address(this));
    }

    /// @inheritdoc BaseStrategy
    function getMetadata() external override view returns (bytes4 interfaceId, bytes memory data) {
        return (type(ITradeFintechStrategy).interfaceId, abi.encode(depositLimit, depositPeriodEnds, lockPeriodEnds));
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        _totalAssets = _getTotalAssets();
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
        if (block.timestamp > depositPeriodEnds) revert DepositPeriodEnded();
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

    /// @inheritdoc BaseStrategy
    function _emergencyWithdraw(uint256 amount) internal override {
        uint256 locked = totalInvested;
        if (amount > locked) revert InsufficientFundsLocked(amount, locked);

        address manager = TokenizedStrategy.management();
        uint256 amountToTransfer = Math.min(amount, asset.balanceOf(manager));

        asset.safeTransferFrom(manager, address(this), amountToTransfer);
        totalInvested -= amountToTransfer;
    }

    function _getTotalAssets() internal view returns (uint256) {
        return totalInvested + asset.balanceOf(address(this));
    }
}
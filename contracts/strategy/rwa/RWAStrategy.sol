// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { BaseStrategy } from "../BaseStrategy.sol";
import { IRWAStrategy } from "./IRWAStrategy.sol";

// solhint-disable
contract RWAStrategy is BaseStrategy, IRWAStrategy {
    using SafeERC20 for ERC20;
    using Math for uint256;

    // The minimum amount to send to the manager
    uint256 public minDeployAmount;
    uint256 public depositLimit;
    uint256 public totalInvested;

    // The address that we send funds to
    // and that will buy RWAs with the funds
    address public immutable managerAddress;

    modifier onlyRWAManager() {
        if (msg.sender != managerAddress) {
            revert NotRWAManager();
        }
        _;
    }

    constructor(
        address asset,
        string memory name,
        address tokenizedStrategyAddress,
        address manager,
        uint256 minDeploy,
        uint256 maxDeposit
    ) BaseStrategy(asset, name, tokenizedStrategyAddress) {
        if (manager == address(0)) {
            revert ZeroManager();
        }
        if (minDeploy > ERC20(asset).totalSupply()) {
            revert InvalidMinDeployAmount();
        }
        if (maxDeposit == 0) {
            revert InvalidDepositLimit();
        }
        managerAddress = manager;
        minDeployAmount = minDeploy;
        depositLimit = maxDeposit;
    }

    /// @inheritdoc IRWAStrategy
    function reportGain(uint256 amount) external onlyRWAManager {
        if (amount == 0) revert ZeroAmount();
        
        asset.safeTransferFrom(managerAddress, address(this), amount);
        emit GainReported(msg.sender, amount);
    }
        
    /// @inheritdoc IRWAStrategy
    function reportLoss(uint256 amount) external onlyRWAManager {
        if (amount == 0) revert ZeroAmount();
        if (amount > totalInvested) revert InvalidLossAmount();
        
        totalInvested -= amount;
        emit LossReported(msg.sender, amount);
    }

    /// @inheritdoc IRWAStrategy
    function setDepositLimit(uint256 newValue) external onlyManagement {
        // require(_depositLimit > 0, "Deposit limit must be greater than 0."); // VK: don't need this check
        if (newValue == 0 || newValue < asset.balanceOf(address(this)) + totalInvested) {
            revert InvalidDepositLimit();
        }

        depositLimit = newValue;
        emit DepositLimitSet(msg.sender, newValue);
    }

    /// @inheritdoc IRWAStrategy
    function setMinDeployAmount(uint256 newValue) external onlyManagement {
        if (newValue > ERC20(asset).totalSupply()) {
            revert InvalidMinDeployAmount();
        }

        minDeployAmount = newValue;
        emit MinDeployAmountSet(msg.sender, newValue);
    }

    /// @inheritdoc BaseStrategy
    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        uint256 deposited = asset.balanceOf(address(this)) + totalInvested;
        return depositLimit < deposited ? 0 : depositLimit - deposited;
    }

    /// @inheritdoc BaseStrategy
    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        return asset.balanceOf(address(this)) + totalInvested;
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        uint256 idle = asset.balanceOf(address(this));
        _totalAssets = totalInvested + idle;

        if (!TokenizedStrategy.isShutdown()) {
            // deposit any loose funds
            _deployFunds(idle);
        }
    }

    /// @inheritdoc BaseStrategy
    function _deployFunds(uint256 amount) internal override {
        if (amount > 0 && amount >= minDeployAmount) {
            // we cannot deposit more than the deposit limit
            uint256 amountToTransfer = Math.min(amount, depositLimit - totalInvested);
            asset.transfer(managerAddress, amountToTransfer);
            totalInvested += amountToTransfer;
        }
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(uint256 amount) internal override {
        uint256 invested = totalInvested;
        if (amount > invested) revert InsufficientFundsLocked(amount, invested);

         uint256 managerBalance = asset.balanceOf(managerAddress);
        if (amount > managerBalance) {
            revert ManagerBalanceTooLow(managerBalance, amount);
        }

        asset.safeTransferFrom(managerAddress, address(this), amount);
        totalInvested -= amount;
    }

    /// @inheritdoc BaseStrategy
    function _emergencyWithdraw(uint256 amount) internal override {
        uint256 locked = totalInvested;
        if (amount > locked) {
            revert InsufficientFundsLocked(amount, locked);
        }

        uint256 amountToTransfer = Math.min(amount, asset.balanceOf(managerAddress));

        asset.transferFrom(managerAddress, address(this), amountToTransfer);
        totalInvested -= amountToTransfer;
    }
}

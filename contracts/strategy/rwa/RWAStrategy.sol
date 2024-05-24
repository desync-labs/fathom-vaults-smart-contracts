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
        address _asset,
        string memory _name,
        address _tokenizedStrategyAddress,
        address _managerAddress,
        uint256 _minDeployAmount,
        uint256 _depositLimit
    ) BaseStrategy(_asset, _name, _tokenizedStrategyAddress) {
        if (_managerAddress == address(0)) {
            revert ZeroManager();
        }
        if (_minDeployAmount > ERC20(_asset).totalSupply()) {
            revert InvalidMinDeployAmount();
        }
        if (_depositLimit == 0) {
            revert InvalidDepositLimit();
        }
        managerAddress = _managerAddress;
        minDeployAmount = _minDeployAmount;
        depositLimit = _depositLimit;
    }

    /// @inheritdoc IRWAStrategy
    function reportGainOrLoss(uint256 _amount, bool isGain) external onlyRWAManager {
        if (isGain) {
            asset.safeTransferFrom(managerAddress, address(this), _amount);
            emit GainReported(_amount);
        } else {
            if (_amount == 0 || _amount > totalInvested) {
                revert InvalidLossAmount();
            }
            
            totalInvested -= _amount;
            emit LossReported(_amount);
        }
    }
    /// @inheritdoc IRWAStrategy
    function setDepositLimit(uint256 _depositLimit) external onlyManagement {
        // require(_depositLimit > 0, "Deposit limit must be greater than 0."); // VK: don't need this check
        if (_depositLimit == 0 || _depositLimit < asset.balanceOf(address(this)) + totalInvested) {
            revert InvalidDepositLimit();
        }

        depositLimit = _depositLimit;
        emit DepositLimitSet(_depositLimit);
    }

    /// @inheritdoc IRWAStrategy
    function setMinDeployAmount(uint256 _minDeployAmount) external onlyManagement {
        if (_minDeployAmount > ERC20(asset).totalSupply()) {
            revert InvalidMinDeployAmount();
        }

        minDeployAmount = _minDeployAmount;
        emit MinDeployAmountSet(_minDeployAmount);
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
    function _deployFunds(uint256 _amount) internal override {
        if (_amount > 0 && _amount >= minDeployAmount) {
            // we cannot deposit more than the deposit limit
            uint256 amountToTransfer = Math.min(_amount, depositLimit - totalInvested);
            asset.transfer(managerAddress, amountToTransfer);
            totalInvested += amountToTransfer;
        }
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(uint256 _amount) internal override {
        if (_amount > 0) {
            if (_amount > asset.balanceOf(address(managerAddress))) {
                revert ManagerBalanceTooLow();
            }
            asset.safeTransferFrom(managerAddress, address(this), _amount);
            totalInvested -= _amount;
        }
    }

    /// @inheritdoc BaseStrategy
    function _emergencyWithdraw(uint256 _amount) internal override {
        uint256 balance = asset.balanceOf(address(this));
        uint256 amountToTransfer;

        if (_amount > balance) {
             // we cannot withdraw from manager more than the total invested
            uint256 availableManagerBalance = Math.min(asset.balanceOf(managerAddress), totalInvested);
            uint256 amountToWithdraw = Math.min(_amount - balance, availableManagerBalance);
            _freeFunds(amountToWithdraw);

            amountToTransfer = asset.balanceOf(address(this));
        } else {
            amountToTransfer = _amount;
        }

        asset.transfer(TokenizedStrategy.management(), amountToTransfer);
    }
}

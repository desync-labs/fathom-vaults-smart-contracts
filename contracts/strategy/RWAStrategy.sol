// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

import "./BaseStrategy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

// solhint-disable
contract RWAStrategy is BaseStrategy {
    using SafeERC20 for ERC20;
    using Math for uint256;

    // The minimum amount to send to the manager
    uint256 public minAmount;

    // The address that we send funds to
    // and that will buy RWAs with the funds
    address public immutable managerAddress;

    uint256 public totalInvestedInRWA;
    uint256 public totalGains;
    uint256 public totalLosses;

    error ZeroAddress();

    constructor(
        address _asset,
        string memory _name,
        address _tokenizedStrategyAddress,
        address _managerAddress,
        uint256 _minAmount
    ) BaseStrategy(_asset, _name, _tokenizedStrategyAddress) {
        if (_managerAddress == address(0)) {
            revert ZeroAddress();
        }
        managerAddress = _managerAddress;
        minAmount = _minAmount;
    }

    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        if (!TokenizedStrategy.isShutdown()) {
            // deposit any loose funds
            uint256 looseAsset = asset.balanceOf(address(this));
            if (looseAsset > minAmount) {
                uint256 _amount = Math.min(looseAsset, availableDepositLimit(address(this)));
                asset.transfer(managerAddress, _amount);
                totalInvestedInRWA += _amount;
            }
        }
        _totalAssets = totalInvestedInRWA + asset.balanceOf(address(this));
    }

    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        // Return the remaining room.
        return type(uint256).max - asset.balanceOf(address(this));
    }

    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        return TokenizedStrategy.totalIdle() + totalInvestedInRWA;
    }

    function _deployFunds(uint256 _amount) internal override {
        if (_amount > minAmount) {
            asset.transfer(managerAddress, _amount);
            totalInvestedInRWA += _amount;
        }
    }

    function _freeFunds(uint256 _amount) internal override {
        // We don't check available liquidity because we need the tx to
        // revert if there is not enough liquidity so we don't improperly
        // pass a loss on to the user withdrawing.
        asset.safeTransferFrom(managerAddress, address(this), _amount);
        totalInvestedInRWA -= _amount;
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        uint256 amountToWithdraw = Math.min(_amount, totalInvestedInRWA);
        asset.safeTransferFrom(managerAddress, address(this), amountToWithdraw);
        asset.transfer(TokenizedStrategy.management(), amountToWithdraw);
        totalInvestedInRWA -= amountToWithdraw;
    }

    function setMinAmount(uint256 _minAmount) external onlyManagement {
        minAmount = _minAmount;
    }

    /// @notice Allows the manager to report gains or losses.
    /// @dev Should be called before calling report() to report the amount of the gain or loss.
    /// @dev The manager can only report gains or losses.
    /// @param _gain The amount of the gain.
    /// @param _loss The amount of the loss.
    function reportGainOrLoss(uint256 _gain, uint256 _loss) external {
        require(msg.sender == managerAddress, "Only the manager can report gains or losses");

        if (_gain > 0) {
            require(_loss == 0, "Cannot report both gain and loss");
            // Transfer the gain from the manager to the strategy contract
            ERC20(asset).safeTransferFrom(managerAddress, address(this), _gain);
            totalGains += _gain;
        } else if (_loss > 0) {
            require(_loss <= totalInvestedInRWA, "Cannot report loss more than total invested");
            totalLosses += _loss;
            totalInvestedInRWA -= _loss;
        }
    }
}

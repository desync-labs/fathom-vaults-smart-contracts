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

    // Mapping to be set by management for any reward tokens.
    // This can be used to set different mins for different tokens
    // or to set to uint256.max if selling a reward token is reverting
    // to allow for reports to still work properly.
    uint256 public minAmountToSell;

    // The address that we send funds to
    // and that will buy RWAs with the funds
    address public immutable managerAddress;

    uint256 public totalInvestedInRWA;

    constructor(address _asset, string memory _name, address _tokenizedStrategyAddress, address _managerAddress, uint256 _minAmountToSell) BaseStrategy(_asset, _name, _tokenizedStrategyAddress) {
        managerAddress = _managerAddress;
        minAmountToSell = _minAmountToSell;
    }

    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        if (!TokenizedStrategy.isShutdown()) {
            // deposit any loose funds
            uint256 looseAsset = asset.balanceOf(address(this));
            if (looseAsset > minAmountToSell) {
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
        if (_amount > minAmountToSell) {
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
        totalInvestedInRWA -= amountToWithdraw;
    }

    function setMinAmountToSell(uint256 _minAmountToSell) external onlyManagement {
        minAmountToSell = _minAmountToSell;
    }
}

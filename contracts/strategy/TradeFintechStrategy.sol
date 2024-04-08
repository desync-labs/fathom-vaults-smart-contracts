// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

import "./BaseStrategy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

// solhint-disable
contract TradeFintechStrategy is BaseStrategy, AccessControl {
    using SafeERC20 for ERC20;
    using Math for uint256;

    // The address that we send funds to
    // and that will buy RWAs with the funds
    address public immutable managerAddress;

    bytes32 public constant MANAGER = keccak256("MANAGER");

    uint256 public totalInvested;
    uint256 public totalGains;
    uint256 public totalLosses;
    uint256 public depositLimit;

    // Define periods
    uint256 public depositPeriodEnds;
    uint256 public lockPeriodEnds;

    event FundsReturned(uint256 amount);
    event GainReported(uint256 gain);
    event LossReported(uint256 loss);

    constructor(
        address _asset,
        string memory _name,
        address _tokenizedStrategyAddress,
        address _managerAddress,
        uint256 _depositPeriodEnds,
        uint256 _lockPeriodEnds,
        uint256 _depositLimit
    ) BaseStrategy(_asset, _name, _tokenizedStrategyAddress) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        managerAddress = _managerAddress;
        depositPeriodEnds = _depositPeriodEnds;
        lockPeriodEnds = _lockPeriodEnds;
        depositLimit = _depositLimit;
    }

    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        if (!TokenizedStrategy.isShutdown()) {
            // deposit any loose funds
            uint256 looseAsset = asset.balanceOf(address(this));
            if (looseAsset > 0) {
                uint256 _amount = Math.min(looseAsset, availableDepositLimit(address(this)));
                asset.transfer(managerAddress, _amount);
                totalInvested += _amount;
            }
        }
        _totalAssets = totalInvested + asset.balanceOf(address(this));
    }

    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        // Return the remaining room.
        return depositLimit - asset.balanceOf(address(this));
    }

    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        return TokenizedStrategy.totalIdle() + totalInvested;
    }

    function _deployFunds(uint256 _amount) internal override {
        require(block.timestamp <= depositPeriodEnds, "Deposit period has ended");
        asset.transfer(managerAddress, _amount);
        totalInvested += _amount;
    }

    function _freeFunds(uint256 _amount) internal override {
        require(block.timestamp > lockPeriodEnds, "Lock period has not ended");
        // We don't check available liquidity because we need the tx to
        // revert if there is not enough liquidity so we don't improperly
        // pass a loss on to the user withdrawing.
        asset.safeTransferFrom(managerAddress, address(this), _amount);
        totalInvested -= _amount;
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
        uint256 amountToWithdraw = Math.min(_amount, totalInvested);
        asset.safeTransferFrom(managerAddress, address(this), amountToWithdraw);
        uint256 totalIdle = asset.balanceOf(address(this));
        asset.transfer(TokenizedStrategy.management(), totalIdle);
        totalInvested -= amountToWithdraw;
    }

    /// @notice Allows the manager to report gains or losses.
    /// @dev Should be called before calling report() to report the amount of the gain or loss.
    /// @dev The manager can only report gains or losses.
    /// @param _gain The amount of the gain.
    /// @param _loss The amount of the loss.
    function reportGainOrLoss(uint256 _gain, uint256 _loss) external onlyRole(MANAGER) {
        if (_gain > 0) {
            require(_loss == 0, "Cannot report both gain and loss");
            totalGains += _gain;
            emit GainReported(_gain);
        } else if (_loss > 0) {
            require(_loss <= totalInvested, "Cannot report loss more than total invested");
            totalLosses += _loss;
            totalInvested -= _loss;
            emit LossReported(_loss);
        }
    }

    /// @notice Allows the manager to return the funds.
    /// @param _amount The amount that is being returned.
    function returnFunds(uint256 _amount) external onlyRole(MANAGER) {
        require(_amount > 0, "Amount must be greater than 0.");

        // Transfer the amount from the manager to the strategy contract
        asset.safeTransferFrom(managerAddress, address(this), _amount);

        emit FundsReturned(_amount);
    }
}

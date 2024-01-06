// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.19;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IInvestor.sol";
import "./interfaces/IStrategy.sol";

contract StrategyInvestor is AccessControl, ReentrancyGuard, IInvestor {
    using SafeERC20 for ERC20;

    ERC20 public immutable STRATEGY_ASSET;
    IStrategy public immutable STRATEGY;

    uint256 public distributionStart;
    uint256 public distributionEnd;
    uint256 public lastReport;

    uint256 internal rewardInSecond;

    error ZeroAddress();
    error DistributionEnded();
    error DistributionNotEnded();
    error DistributionNotStarted();
    error PeriodStartInPast();
    error WrongPeriod();
    error WrongBalance();
    error ZeroAmount();
    error WrongAmount();

    constructor(address _strategy) {
        if (_strategy == address(0)) {
            revert ZeroAddress();
        }
        STRATEGY = IStrategy(_strategy);
        STRATEGY_ASSET = ERC20(STRATEGY.asset());

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // solhint-disable-next-line code-complexity
    function setupDistribution(
        uint256 approxAmount,
        uint256 periodStart,
        uint256 periodEnd
    ) external override nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (lastReport < distributionEnd) revert DistributionNotEnded();
        if (periodStart <= block.timestamp) revert PeriodStartInPast();
        if (periodEnd <= periodStart) revert WrongPeriod();
        if (approxAmount == 0) revert ZeroAmount();

        uint256 accrualInSecond = approxAmount / (periodEnd - periodStart);
        if (accrualInSecond == 0) revert WrongAmount();
        rewardInSecond = accrualInSecond;
        uint256 realDistributionAmount = accrualInSecond * (periodEnd - periodStart);

        distributionStart = periodStart;
        distributionEnd = periodEnd;
        lastReport = periodStart;

        emit DistributionSetup(realDistributionAmount, periodStart, periodEnd);

        uint256 balance = STRATEGY_ASSET.balanceOf(address(this));
        if (balance < realDistributionAmount) {
            // Transfer the difference, there might be some left from the previous distribution
            _erc20SafeTransferFrom(address(STRATEGY_ASSET), msg.sender, address(this), realDistributionAmount - balance);
        } else if (balance > realDistributionAmount) {
            // Transfer the difference back to the rewards provider
            _erc20SafeTransfer(address(STRATEGY_ASSET), msg.sender, balance - realDistributionAmount);
        } // else balance == realDistributionAmount, nothing to do
        if (STRATEGY_ASSET.balanceOf(address(this)) != realDistributionAmount) revert WrongBalance();
    }

    function processReport() external override nonReentrant returns (uint256) {
        if (lastReport >= distributionEnd) revert DistributionEnded();
        if (block.timestamp < distributionStart) revert DistributionNotStarted();

        uint256 accruedRewards = rewardsAccrued();
        if (accruedRewards == 0) return 0;

        lastReport = block.timestamp > distributionEnd ? distributionEnd : block.timestamp;

        emit Report(lastReport, accruedRewards);

        _erc20SafeTransfer(address(STRATEGY_ASSET), address(STRATEGY), accruedRewards);

        return accruedRewards;
    }

    function emergencyWithdraw() external override nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
        uint256 balance = STRATEGY_ASSET.balanceOf(address(this));
        if (balance == 0) revert ZeroAmount();

        rewardInSecond = 0;
        distributionStart = 0;
        distributionEnd = 0;
        lastReport = 0;

        emit EmergencyWithdraw(block.timestamp, balance);

        _erc20SafeTransfer(address(STRATEGY_ASSET), msg.sender, balance);

        return balance;
    }

    function asset() external view override returns (address) {
        return address(STRATEGY_ASSET);
    }

    function rewardRate() external view override returns (uint256) {
        return rewardInSecond;
    }

    function totalRewards() external view override returns (uint256) {
        return rewardInSecond * (distributionEnd - distributionStart);
    }

    function distributedRewards() external view override returns (uint256) {
        return rewardInSecond * (lastReport - distributionStart);
    }

    function rewardsLeft() public view override returns (uint256) {
        return rewardInSecond * (distributionEnd - lastReport);
    }

    function rewardsAccrued() public view override returns (uint256) {
        if (lastReport == distributionEnd || block.timestamp <= distributionStart) {
            return 0;
        } else if (block.timestamp >= distributionEnd) {
            return rewardsLeft();
        } else {
            return rewardInSecond * (block.timestamp - lastReport);
        }
    }

    function _erc20SafeTransferFrom(address token, address sender, address receiver, uint256 amount) internal {
        if (token == address(0) || sender == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        ERC20(token).safeTransferFrom(sender, receiver, amount);
    }

    function _erc20SafeTransfer(address token, address receiver, uint256 amount) internal {
        if (token == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        ERC20(token).safeTransfer(receiver, amount);
    }
}

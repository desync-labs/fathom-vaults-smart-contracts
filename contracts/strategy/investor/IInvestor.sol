// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023
pragma solidity 0.8.19;

interface IInvestor {
    event DistributionSetup(uint256 amount, uint256 periodStart, uint256 periodEnd);
    event Report(uint256 timestamp, uint256 accruedRewards);
    event EmergencyWithdraw(uint256 timestamp, uint256 leftRewards);
    event StrategyUpdate(address oldStrategy, address newStrategy, address newStrategyAsset);

    function setStrategy(address _strategy) external;

    function setupDistribution(uint256 amount, uint256 periodStart, uint256 periodEnd) external;

    function processReport() external returns (uint256);

    function emergencyWithdraw() external returns (uint256);

    function rewardRate() external view returns (uint256);

    function totalRewards() external view returns (uint256);

    function distributedRewards() external view returns (uint256);

    function rewardsLeft() external view returns (uint256);

    function rewardsAccrued() external view returns (uint256);

    function asset() external view returns (address);
}

// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.19;

interface IInvestor {
    event DistributionSetup(uint256 amount, uint256 periodStart, uint256 periodEnd);
    event Report(uint256 timestamp, uint256 accruedRewards);
    event DistributionCancelled(uint256 timestamp, uint256 leftRewards);

    function setupDistribution(uint256 amount, uint256 periodStart, uint256 periodEnd) external;

    function processReport() external returns (uint256);

    function cancelDistribution() external returns (uint256);

    function rewardRate() external view returns (uint256);

    function totalRewards() external view returns (uint256);

    function distributedRewards() external view returns (uint256);

    function rewardsLeft() external view returns (uint256);

    function rewardsAccrued() external view returns (uint256);

    function asset() external view returns (address);
}

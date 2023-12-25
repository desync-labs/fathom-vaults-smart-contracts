// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

interface IStrategyManagerPackage {
    // solhint-disable ordering
    function initialize(address _asset, address _sharesManager) external;
    function addStrategy(address newStrategy) external;
    function revokeStrategy(address strategy, bool force) external;
    function updateMaxDebtForStrategy(address strategy, uint256 newMaxDebt) external;
    function updateDebt(address sender, address strategy, uint256 targetDebt) external returns (uint256);
    function processReport(address strategy) external returns (uint256, uint256);
    function getDefaultQueueLength() external view returns (uint256 length);
    function getDefaultQueue() external view returns (address[] memory);
    function getDebt(address strategy) external view returns (uint256);
    function setDebt(address strategy, uint256 _newDebt) external;
    function setFees(uint256 totalFees, uint256 totalRefunds, uint256 protocolFees, address protocolFeeRecipient) external;
}

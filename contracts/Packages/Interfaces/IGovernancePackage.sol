// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.16;

interface IGovernancePackage {
    function initialize(address _sharesManager) external;
    function buyDebt(address strategy, uint256 amount) external;
    function shutdownVault() external;
}
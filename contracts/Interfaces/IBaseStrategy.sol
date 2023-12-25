// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

interface IBaseStrategy {
    function deployFunds(uint256 _assets) external;

    function freeFunds(uint256 _amount) external;

    function harvestAndReport() external returns (uint256);

    function tendThis(uint256 _totalIdle) external;

    function shutdownWithdraw(uint256 _amount) external;

    function tokenizedStrategyAddress() external view returns (address);

    function availableDepositLimit(address _owner) external view returns (uint256);

    function availableWithdrawLimit(address _owner) external view returns (uint256);

    function tendTrigger() external view returns (bool, bytes memory);
}

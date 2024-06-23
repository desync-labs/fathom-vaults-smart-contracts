// SPDX-License-Identifier: AGPL-3.0
// Modified Copyright Fathom 2023
// Original Copyright Yearn.finance

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

    /// @notice Get metadata of the strategy
    /// @return interfaceId strategy interface id
    /// @return data encoded metadata specific to the strategy
    function getMetadata() external view returns (bytes4 interfaceId, bytes memory data);
}

// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.19;

import { IUniswapV2Router02 } from "./interfaces/IUniswapV2Router02.sol";
interface ILiquidationStrategy {
    function setStrategyManager(address _strategyManager) external;
    function setFixedSpreadLiquidationStrategy(address _fixedSpreadLiquidationStrategy) external;
    function setBookKeeper(address _bookKeeper) external;
    function setV3Info(address _permit2, address _universalRouter, uint24 _poolFee) external;
    function sellCollateralV2(address _collateral, IUniswapV2Router02 _router, uint256 _amount, uint256 _minAmountOut) external;
    function sellCollateralV3(address _collateral, address _universalRouter, uint256 _amount) external;
    function shutdownWithdrawCollateral(address _collateral, uint256 _amount) external;
    function idleCollateral(address) external view returns (uint256 CollateralAmount, uint256 amountNeededToPayDebt, uint256 averagePriceOfWXDC);
}

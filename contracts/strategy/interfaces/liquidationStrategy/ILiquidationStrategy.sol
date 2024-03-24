// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.19;

import { IUniswapV2Router02 } from "./IUniswapV2Router02.sol";
interface ILiquidationStrategy {
    function setStrategyManager(address _strategyManager) external;
    function setFixedSpreadLiquidationStrategy(address _fixedSpreadLiquidationStrategy) external;
    function setBookKeeper(address _bookKeeper) external;
    function setV3Info(address _permit2, address _universalRouter) external;
    function setAllowLoss(bool _allowLoss) external;
    function sellWXDCV2(IUniswapV2Router02 _router, uint256 _amount, uint256 _minAmountOut) external;
    function sellWXDCV3(address _universalRouter, uint256 _amount) external;
    function shutdownWithdrawWXDC(uint256 _amount) external;
    function idleWXDC() external view returns(uint256 WXDCAmount, uint256 amountNeededToPayDebt, uint256 averagePriceOfWXDC);
}

// SPDX-License-Identifier: AGPL-3.0
// Modified Copyright Fathom 2023
// Original Copyright Yearn.finance

pragma solidity 0.8.19;

interface ILender {
    function setUniFees(
        address _token0,
        address _token1,
        uint24 _fee
    ) external;

    function getSupplyCap() external returns (uint256);

    function sellRewardManually(
        address _token,
        uint256 _amount,
        uint256 _minAmountOut
    ) external;

    function setMinAmountToSellMapping(
        address _token,
        uint256 _amount
    ) external;

    function setClaimRewards(bool _bool) external;

    function setRewardsController(address _rewardsController) external;
}

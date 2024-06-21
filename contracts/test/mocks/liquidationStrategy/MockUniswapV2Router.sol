// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.19;

import { IToken } from "../../../strategy/liquidation/interfaces/IToken.sol";

contract MockUniswapV2Router {
    uint256 public amountsOut;
    address public collateralToken;
    address public stablecoin;
    bool public giveLessFXD;
    constructor(address _collateralToken, address _stablecoin) {
        collateralToken = _collateralToken;
        stablecoin = _stablecoin;
    }

    function setAmountsOut(uint256 _amountsOut) external {
        amountsOut = _amountsOut;
    }

    function setGiveLessFXD(bool _giveLessFXD) external {
        giveLessFXD = _giveLessFXD;
    }

    function getAmountsOut(uint256 _collateralAmountToLiquidate, address[] calldata /* _path */) external view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = _collateralAmountToLiquidate;
        amounts[1] = amountsOut;
        return amounts;
    }

    function swapExactTokensForTokens(
        uint256 _amount,
        uint256 _minAmountOut,
        address[] calldata /* _path */,
        address _to,
        uint256 /* _deadline */
    ) external returns (uint256[] memory amounts) {
        IToken(collateralToken).transferFrom(msg.sender, address(this), _amount);
        if (giveLessFXD == true) {
            IToken(stablecoin).transfer(_to, _minAmountOut / 10);
        } else {
            IToken(stablecoin).transfer(_to, _minAmountOut);
        }
        amounts = new uint256[](2);
        amounts[0] = _amount;
        amounts[1] = _minAmountOut;
        return amounts;
    }
}

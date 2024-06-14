// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023
pragma solidity 0.8.19;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IUniversalRouter } from "../interfaces/liquidationStrategy/IUniversalRouter.sol";
import { IPermit2 } from "../interfaces/liquidationStrategy/IPermit2.sol";

/**
 *   @title UniversalSwapper
 *   @dev This is a simple contract that can be inherited by any tokenized
 *   strategy that would like to use UniversalRouter for swaps. It holds all needed
 *   logic to perform both exact input and exact output swaps.
 *
 *   The global address variables default to the ETH mainnet addresses but
 *   remain settable by the inheriting contract to allow for customization
 *   based on needs or chain it's used on.
 *
 *   Please make sure you set router as universalRouter, permit2 address and
 *   uniFees of swap pairs in the inheriting contract.
 */
// solhint-disable
contract UniversalSwapper {
    using SafeERC20 for ERC20;

    // Address of base Token.
    address public base;

    // Address of Universal Router.
    address public router;

    // Address of Permit2.
    address public permit2;

    // Fees for the pools. Each fee should get set each way in
    // the mapping so no matter the direction the correct fee will get
    // returned for any two tokens.
    mapping(address => mapping(address => uint24)) public uniFees;

    /**
     * @dev All fees will default to 0 on creation. A strategist will need
     * to set the mapping for the tokens expected to swap. This function
     * is to help set the mapping. It can be called internally during
     * initialization, through permissioned functions, etc.
     */
    function _setUniFees(address _token0, address _token1, uint24 _fee) internal {
        uniFees[_token0][_token1] = _fee;
        uniFees[_token1][_token0] = _fee;
    }

    /**
     * @dev Used to swap a specific amount of `_from` to `_to`.
     * This will check and handle all allowances as well as not swapping
     * unless `_amountIn` is greater than the set `_minAmountOut`.
     *
     * If one of the tokens matches with the `base` token it will do only
     * one jump, otherwise will do two jumps.
     *
     * The corresponding uniFees for each token pair will need to be set
     * otherwise, this function will revert.
     *
     * @param _from The token we are swapping from.
     * @param _to The token we are swapping to.
     * @param _amountIn The amount of `_from` we will swap.
     * @param _minAmountOut The min of `_to` to get out.
     * @return _amountOut The actual amount of `_to` that was swapped to
     */
    function _swapFrom(address _from, address _to, uint256 _amountIn, uint256 _minAmountOut) internal returns (uint256 _amountOut) {
        _checkAllowance(permit2, _from, _amountIn);

        bytes memory path;
        bytes memory commands;
        bytes[] memory inputs;

        if (_from == base || _to == base) {
            path = abi.encodePacked(_from, uniFees[_from][_to], _to);
        } else {
            path = abi.encodePacked(
                _from, // tokenIn
                uniFees[_from][base], // from-base fee
                base, // base token
                uniFees[base][_to], // base-to fee
                _to // tokenOut
            );
        }

        (commands, inputs) = _encodeSwapExactInput(
            address(this),
            _amountIn,
            _minAmountOut,
            path,
            true
        );

        IPermit2(permit2).approve(_from, router, uint160(_amountIn), uint48(block.timestamp));
        uint256 balanceBefore = ERC20(_to).balanceOf(address(this));
        IUniversalRouter(router).execute(commands, inputs, block.timestamp);
        ERC20(_from).safeApprove(permit2, 0);

        _amountOut = ERC20(_to).balanceOf(address(this)) - balanceBefore;
    }

    /**
     * @dev Internal safe function to make sure the contract you want to
     * interact with has enough allowance to pull the desired tokens.
     *
     * @param _contract The address of the contract that will move the token.
     * @param _token The ERC-20 token that will be getting spent.
     * @param _amount The amount of `_token` to be spent.
     */
    function _checkAllowance(address _contract, address _token, uint256 _amount) internal {
        if (ERC20(_token).allowance(address(this), _contract) < _amount) {
            ERC20(_token).approve(_contract, 0);
            ERC20(_token).approve(_contract, _amount);
        }
    }

    function _encodeSwapExactInput(
        address _recipient,
        uint256 _amountIn,
        uint256 _amountOutMinimum,
        bytes memory _path,
        bool _sourceOfFundsIsMsgSender
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        // Encode the inputs for the V3_SWAP_EXACT_IN COMMAND
        bytes memory input = abi.encode(_recipient, _amountIn, _amountOutMinimum, _path, _sourceOfFundsIsMsgSender);

        // Prepare the COMMAND and input for the caller to use with `execute` function of UniversalRouter
        commands = abi.encodePacked(bytes1(0x00));
        inputs = new bytes[](1);
        inputs[0] = input;
    }
}
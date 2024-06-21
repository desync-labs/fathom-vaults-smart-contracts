// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023
pragma solidity 0.8.19;

import {BaseStrategy} from "../BaseStrategy.sol";
import {IInvestor} from "./IInvestor.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IInvestorStrategy } from "./IInvestorStrategy.sol";

// solhint-disable
contract InvestorStrategy is IInvestorStrategy, BaseStrategy {
    using SafeERC20 for ERC20;

    IInvestor public immutable investor;

    constructor(
        address _investor,
        address _asset,
        string memory _name,
        address _tokenizedStrategyAddress
    ) BaseStrategy(_asset, _name, _tokenizedStrategyAddress) {
        require(_investor != address(0), "InvestorStrategy: zero address");
        investor = IInvestor(_investor);
    }

    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        investor.processReport();
        _totalAssets = asset.balanceOf(address(this));
    }

    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        // Return the remaining room.
        return type(uint256).max - asset.balanceOf(address(this));
    }

    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        return TokenizedStrategy.totalIdle();
    }

    /// @inheritdoc BaseStrategy
    function getMetadata() external override view returns (bytes4 interfaceId, bytes memory data) {
        return (type(IInvestorStrategy).interfaceId, abi.encode(investor));
    }

    function _deployFunds(uint256 _amount) internal pure override {}

    function _freeFunds(uint256 _amount) internal pure override {}

    function _emergencyWithdraw(uint256 _amount) internal override {
        asset.transfer(TokenizedStrategy.management(), _amount);
    }
}

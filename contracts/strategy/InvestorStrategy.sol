// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023
pragma solidity 0.8.19;

import "./TokenizedStrategy.sol";
import "./interfaces/IInvestor.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// solhint-disable
contract InvestorStrategy is TokenizedStrategy {
    using SafeERC20 for ERC20;

    IInvestor public immutable investor;

    uint256 public minDebt;
    uint256 public maxDebt = type(uint256).max;

    /// @notice Private variables and functions used in this mock.
    bytes32 public constant BASE_STRATEGY_STORAGE = bytes32(uint256(keccak256("fathom.base.strategy.storage")) - 1);

    constructor(address _investor, address _asset, string memory _name, address _management, address _keeper, uint32 _profitMaxUnlockTime) {
        require(_investor != address(0), "InvestorStrategy: zero address");
        investor = IInvestor(_investor);

        // Cache storage pointer
        StrategyData storage stor = strategyStorage();

        // Set the strategy's underlying asset
        stor.asset = ERC20(_asset);
        // Set the Strategy Tokens name.
        stor.name = _name;
        // Set decimals based off the `asset`.
        stor.decimals = ERC20(_asset).decimals();

        // Set last report to this block.
        stor.lastReport = uint128(block.timestamp);

        // Set the default management address. Can't be 0.
        require(_management != address(0), "ZERO ADDRESS");
        stor.management = _management;
        stor.performanceFeeRecipient = _management;
        // Set the keeper address
        stor.keeper = _keeper;
        stor.profitMaxUnlockTime = _profitMaxUnlockTime;
    }

    function setMinDebt(uint256 _minDebt) external {
        minDebt = _minDebt;
    }

    function setMaxDebt(uint256 _maxDebt) external {
        maxDebt = _maxDebt;
    }

    function harvestAndReport() external returns (uint256 _totalAssets) {
        investor.processReport();
        _totalAssets = strategyStorage().asset.balanceOf(address(this));
    }

    function availableDepositLimit(address /*_owner*/) public view returns (uint256) {
        // Return the remaining room.
        return type(uint256).max - strategyStorage().asset.balanceOf(address(this));
    }

    function availableWithdrawLimit(address /*_owner*/) public pure returns (uint256) {
        return type(uint256).max;
    }

    function deployFunds(uint256 _amount) external virtual {}

    function freeFunds(uint256 _amount) external virtual {
        strategyStorage().asset.safeTransfer(strategyStorage().management, _amount);
    }

    function strategyStorage() internal pure returns (StrategyData storage stor) {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = BASE_STRATEGY_STORAGE;
        assembly {
            stor.slot := slot
        }
    }
}

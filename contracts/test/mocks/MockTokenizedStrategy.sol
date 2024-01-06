// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

import { TokenizedStrategy, ERC20 } from "../../strategy/TokenizedStrategy.sol";

// solhint-disable comprehensive-interface, custom-errors
contract MockTokenizedStrategy is TokenizedStrategy {
    uint256 public minDebt;
    uint256 public maxDebt = type(uint256).max;

    /// @notice Private variables and functions used in this mock.
    bytes32 public constant BASE_STRATEGY_STORAGE = bytes32(uint256(keccak256("fathom.base.strategy.storage")) - 1);

    constructor(address _asset, string memory _name, address _management, address _keeper, uint32 _profitMaxUnlockTime) {
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

    // solhint-disable-next-line no-empty-blocks
    function deployFunds(uint256 _amount) external virtual {}

    // solhint-disable-next-line no-empty-blocks
    function freeFunds(uint256 _amount) external virtual {}

    function harvestAndReport() external virtual returns (uint256) {
        return strategyStorage().asset.balanceOf(address(this));
    }

    function availableDepositLimit(address) public view virtual returns (uint256) {
        uint256 _totalAssets = strategyStorage().totalIdle;
        uint256 _maxDebt = maxDebt;
        return _maxDebt > _totalAssets ? _maxDebt - _totalAssets : 0;
    }

    function availableWithdrawLimit(address /*_owner*/) public view virtual returns (uint256) {
        return type(uint256).max;
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

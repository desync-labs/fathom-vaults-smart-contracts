// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023
pragma solidity 0.8.19;

import "./BaseStrategy.sol";
import "./interfaces/IInvestor.sol";
import "./interfaces/IInvestorStrategy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract InvestorStrategy is BaseStrategy, IInvestorStrategy {
    using SafeERC20 for ERC20;

    struct Deposit {
        uint256 amount;
        uint256 unlockTime;
    }

    Deposit[] public deposits; // Array to store all deposits
    uint256 public totalLocked = 0;
    uint256 public totalUnlocked = 0;
    uint256 public lockPeriod = 15 days; // Default to 15 days

    IInvestor public immutable INVESTOR;

    constructor(
        address _investor,
        address _asset,
        string memory _name,
        address _tokenizedStrategyAddress
    ) BaseStrategy(_asset, _name, _tokenizedStrategyAddress) {
        require(_investor != address(0), "InvestorStrategy: zero address");
        INVESTOR = IInvestor(_investor);
    }

    // Function to update lock period
    function setLockPeriod(uint256 _newLockPeriod) external onlyManagement {
        lockPeriod = _newLockPeriod;
    }

    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        // Return the remaining room.
        return type(uint256).max - asset.balanceOf(address(this));
    }

    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        return TokenizedStrategy.totalIdle();
    }

    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        INVESTOR.processReport();
        _totalAssets = asset.balanceOf(address(this));
    }

    function _deployFunds(uint256 _amount) internal override {
        deposits.push(Deposit({
            amount: _amount,
            unlockTime: block.timestamp + lockPeriod
        }));
        totalLocked += _amount;
    }

    function _freeFunds(uint256 _amount) internal override {
        updateBalances(); // Update the totalLocked and totalUnlocked balances
        require(_amount <= totalUnlocked, "Not enough unlocked funds");
        totalUnlocked -= _amount; // Deduct the withdrawn amount from totalUnlocked
    }

    function updateBalances() internal {
        uint256 unlockedAmount = 0;
        uint256 currentTime = block.timestamp;
        for (uint i = 0; i < deposits.length; i++) {
            if (currentTime >= deposits[i].unlockTime && deposits[i].amount > 0) {
                unlockedAmount += deposits[i].amount;
                deposits[i].amount = 0; // Mark as processed
            }
        }
        totalUnlocked += unlockedAmount;
        totalLocked -= unlockedAmount;
    }
}

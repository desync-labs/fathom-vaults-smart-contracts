// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

error FeeExceedsMax();
error ERC20InsufficientAllowance(uint256 currentAllowance);
error InsufficientFunds();
error ZeroAddress();
error SelfTransfer();
error SelfApprove();
error VaultReceiver();
error ERC20PermitExpired();
error ERC20PermitInvalidSignature(address recoveredAddress);
error InsufficientShares(uint256 balanceOfOwner);
error InactiveStrategy(address strategy);
error InactiveVault();
error ExceedLimit(uint256 recipientMaxDeposit);
error ZeroValue();
error StrategyDebtIsLessThanAssetsNeeded(uint256 strageyCurrentDebt);
error MaxLoss();
error InsufficientAssets(uint256 currTotalIdle, uint256 requestedAssets);
error TooMuchLoss();
error InvalidAssetDecimals();
error AlreadyInitialized();
error AmountTooHigh();
error ERC20ApprovalFailed();
error ERC20TransferFailed();
error InvalidAsset(address asset);
error StrategyAlreadyActive();
error StrategyHasDebt(uint256 debt);
error DebtDidntChange();
error StrategyHasUnrealisedLosses(uint256 unrealisedLosses);
error DebtHigherThanMaxDebt(uint256 newDebt, uint256 maxDebt);
error UsingDepositLimit();
error ProfitUnlockTimeTooLong();
error QueueTooLong();
error UsingModule();
error InvalidModule();

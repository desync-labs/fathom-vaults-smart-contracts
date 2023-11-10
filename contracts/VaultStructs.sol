// SPDX-License-Identifier: AGPL 3.0
// Copyright Fathom 2023

pragma solidity ^0.8.16;

struct StrategyParams {
    uint256 activation;
    uint256 lastReport;
    uint256 currentDebt;
    uint256 maxDebt;
}

struct FeeAssessment {
    uint256 totalFees;
    uint256 totalRefunds;
    uint256 protocolFees;
    address protocolFeeRecipient;
}

struct ShareManagement {
    uint256 sharesToBurn;
    uint256 accountantFeesShares;
    uint256 protocolFeesShares;
}

struct WithdrawalState {
    uint256 requestedAssets;
    uint256 currTotalIdle;
    uint256 currTotalDebt;
    uint256 assetsNeeded;
    uint256 previousBalance;
    uint256 unrealisedLossesShare;
}

// ENUMS
enum StrategyChangeType {
    ADDED, // Corresponds to the strategy being added.
    REVOKED // Corresponds to the strategy being revoked.
}

enum RoleStatusChange {
    OPENED, // Corresponds to a role being opened.
    CLOSED // Corresponds to a role being closed.
}

enum Rounding {
    ROUND_DOWN, // Corresponds to rounding down to the nearest whole number.
    ROUND_UP // Corresponds to rounding up to the nearest whole number.
}
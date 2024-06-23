// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IDepositLimitModule } from "../../vault/interfaces/IDepositLimitModule.sol";

interface IKYCDepositLimitModule is IDepositLimitModule {
    error ZeroAddress();
    error NotKYCProvider();

    /// @notice Set KYC status for a user
    /// can be called only by KYC provider
    /// @param user User address
    /// @param passed KYC status
    function setKYCPassed(address user, bool passed) external;

    /// @notice Set KYC status for multiple users
    /// can be called only by KYC provider
    /// @param users Array of user addresses
    /// @param passed KYC status
    function setKYCPassedBatch(address[] calldata users, bool passed) external;

    /// @notice Set KYC provider
    /// can be called only by owner
    /// @param kycProvider KYC provider address
    function setKYCProvider(address kycProvider) external;

    /// @notice Check if KYC passed for a user
    /// @param user User address
    /// @return KYC status
    function kycPassed(address user) external view returns (bool);
}

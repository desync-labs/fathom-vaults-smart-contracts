// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IDepositLimitModule} from "../../vault/interfaces/IDepositLimitModule.sol";

interface IKYCDepositLimitModule is IDepositLimitModule {
    error ZeroAddress();
    error NotKYCProvider();

    function setKYCPassed(address user, bool passed) external;
    function setKYCPassedBatch(address[] calldata users, bool passed) external;
    function setKYCProvider(address kycProvider) external;
    function kycPassed(address user) external view returns (bool);
}
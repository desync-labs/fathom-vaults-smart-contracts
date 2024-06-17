// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2024
pragma solidity 0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IBaseStrategy} from "../../strategy/interfaces/IBaseStrategy.sol";
import {IKYCDepositLimitModule} from "./IKYCDepositLimitModule.sol";

contract KYCDepositLimitModule is Ownable, IKYCDepositLimitModule {
    IBaseStrategy private _strategy;
    address private _kycProvider;
    mapping(address => bool) private _kycPassed;

    modifier onlyKYCProvider() {
        if (msg.sender != _kycProvider) {
            revert NotKYCProvider();
        }
        _;
    }

    constructor(IBaseStrategy strategy, address kycProvider) {
        if (address(strategy) == address(0) || kycProvider == address(0)) {
            revert ZeroAddress();
        }
        _strategy = strategy;
        _kycProvider = kycProvider;
    }

    function setKYCPassed(address user, bool passed) external onlyKYCProvider {
        _kycPassed[user] = passed;
    }

    function setKYCPassedBatch(address[] calldata users, bool passed) external onlyKYCProvider {
        for (uint256 i = 0; i < users.length; i++) {
            _kycPassed[users[i]] = passed;
        }
    }

    function setKYCProvider(address kycProvider) external onlyOwner {
        if (kycProvider == address(0)) {
            revert ZeroAddress();
        }
        _kycProvider = kycProvider;
    }

    function availableDepositLimit(address receiver) external view override returns (uint256) {
        if (!_kycPassed[receiver]) {
            return 0;
        }
        
        return _strategy.availableDepositLimit(receiver);
    }

    function kycPassed(address user) external view returns (bool) {
        return _kycPassed[user];
    }
}
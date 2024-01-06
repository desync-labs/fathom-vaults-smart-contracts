// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IAccountant.sol";
import "./interfaces/IGenericAccountant.sol";

/// @title GenericAccountant
/// @dev GenericAccountant is a simple accountant that charges a management fee.
/// @dev GenericAccountant isn't giving any refunds in case of losses.
contract GenericAccountant is AccessControl, IAccountant, IGenericAccountant {
    using SafeERC20 for ERC20;

    /// @notice Constant defining the fee basis points.
    uint256 internal constant FEE_BPS = 10000;

    /// @notice Variable defining the management fee;
    uint256 internal _managementFee;
    /// @notice Variable defining the fee recipient.
    address internal _feeRecipient;

    event ManagementFeeSet(uint256 fee);
    event FeeRecipientSet(address feeRecipient);

    error ZeroAddress();
    error ERC20TransferFailed();
    error FeeGreaterThan100();
    error ZeroAmount();

    constructor(uint256 managementFee_, address feeRecipient_, address admin_) {
        if (managementFee_ > FEE_BPS) {
            revert FeeGreaterThan100();
        }
        if (feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        _managementFee = managementFee_;
        _feeRecipient = feeRecipient_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function setManagementFee(uint256 fee) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fee > FEE_BPS) {
            revert FeeGreaterThan100();
        }
        emit ManagementFeeSet(fee);
    }

    function setFeeRecipient(address recipient) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        _feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function distribute(address token) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 balance = ERC20(token).balanceOf(address(this));
        if (balance == 0) {
            revert ZeroAmount();
        }
        _erc20SafeTransfer(token, _feeRecipient, balance);
    }

    function report(address /*strategy*/, uint256 gain, uint256 /*loss*/) external view override returns (uint256, uint256) {
        return ((gain * _managementFee) / FEE_BPS, 0);
    }

    function feeRecipient() external view override returns (address) {
        return _feeRecipient;
    }

    function managementFee() external view override returns (uint256) {
        return _managementFee;
    }

    function _erc20SafeTransfer(address token, address receiver, uint256 amount) internal {
        if (token == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        ERC20(token).safeTransfer(receiver, amount);
    }
}

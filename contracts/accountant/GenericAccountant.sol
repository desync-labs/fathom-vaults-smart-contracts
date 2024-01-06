// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IAccountant.sol";

/// @title GenericAccountant
/// @dev GenericAccountant is a simple accountant that charges a management fee.
/// @dev GenericAccountant isn't giving any refunds in case of losses.
// solhint-disable custom-errors
contract GenericAccountant is AccessControl, IAccountant {
    /// @notice Constant defining the fee basis points.
    uint256 internal constant FEE_BPS = 10000;

    /// @notice Variable defining the management fee;
    uint256 public managementFee;
    /// @notice Variable defining the fee recipient.
    address public feeRecipient;

    event ManagementFeeSet(uint256 fee);
    event FeeRecipientSet(address feeRecipient);

    error ZeroAddress();
    error ERC20TransferFailed();
    error FeeGreaterThan100();
    error ZeroAmount();

    constructor(uint256 _managementFee, address _feeRecipient, address _admin) {
        if (_managementFee > FEE_BPS) {
            revert FeeGreaterThan100();
        }
        if (_feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        managementFee = _managementFee;
        feeRecipient = _feeRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    // solhint-disable-next-line comprehensive-interface
    function setManagementFee(uint256 fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fee > FEE_BPS) {
            revert FeeGreaterThan100();
        }
        emit ManagementFeeSet(fee);
    }

    // solhint-disable-next-line comprehensive-interface
    function setFeeRecipient(address _feeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        feeRecipient = _feeRecipient;
        emit FeeRecipientSet(_feeRecipient);
    }

    // solhint-disable-next-line comprehensive-interface
    function distribute(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 balance = IERC20Metadata(token).balanceOf(address(this));
        if (balance == 0) {
            revert ZeroAmount();
        }
        _erc20SafeTransfer(token, feeRecipient, balance);
    }

    function report(address /*strategy*/, uint256 gain, uint256 /*loss*/) external view override returns (uint256, uint256) {
        return ((gain * managementFee) / FEE_BPS, 0);
    }

    /// @notice Used only to send tokens that are not the type managed by this Vault.
    /// Used to handle non-compliant tokens like USDT
    function _erc20SafeTransfer(address token, address receiver, uint256 amount) internal {
        if (token == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        if (!IERC20Metadata(token).transfer(receiver, amount)) {
            revert ERC20TransferFailed();
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

interface IGenericAccountant {
    event PerformanceFeeSet(uint256 fee);
    event FeeRecipientSet(address feeRecipient);

    function setPerformanceFee(uint256 fee) external;

    function setFeeRecipient(address _feeRecipient) external;

    function distribute(address token) external;

    function feeRecipient() external view returns (address);

    function performanceFee() external view returns (uint256);
}

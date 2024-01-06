// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

interface IFactoryInit {
    function initialize(address _vaultPackage, address _feeRecipient, uint16 _feeBPS) external;
}

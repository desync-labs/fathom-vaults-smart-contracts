// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "../common/ReentrancyGuard.sol";

contract FactoryStorage is AccessControl {
    uint16 public constant MAX_BPS = 10000;

    uint16 public feeBPS;
    address public feeRecipient;
    address[] public vaults;
    address[] public vaultPackages;

    /// @notice Initialized state of the factory.
    bool public initialized;

    mapping(address => address) public vaultCreators;
}

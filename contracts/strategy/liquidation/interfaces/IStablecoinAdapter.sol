// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.19;

interface IStablecoinAdapter {
    function deposit(address positionAddress, uint256 wad, bytes calldata data) external;
}

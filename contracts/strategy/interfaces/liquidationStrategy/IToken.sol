// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.19;

interface IToken {
    function transfer(address, uint256) external returns (bool);

    function transferFrom(address, address, uint256) external returns (bool);

    function approve(address, uint256) external returns (bool);

    function balanceOf(address) external view returns (uint256);

    function decimals() external view returns (uint8);
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

interface IFactory {
    function protocolFeeConfig() external view returns (uint16, address);
}

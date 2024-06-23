// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023
pragma solidity 0.8.19;

import {IInvestor} from "./IInvestor.sol";

interface IInvestorStrategy {
    function investor() external view returns (IInvestor);
}

// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.19;

import { IToken } from "../../../strategy/interfaces/liquidationStrategy/IToken.sol";

contract MockStablecoinAdapter {
    address public stablecoin;
    constructor(address _stablecoin) {
        stablecoin = _stablecoin;
    }

    function deposit(address /* _usr */, uint256 _wad, bytes calldata /* data */) external {
        IToken(stablecoin).transferFrom(msg.sender, address(this), _wad);
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.19;

import { IToken } from "../../../strategy/interfaces/liquidationStrategy/IToken.sol";
/// @title CollateralTokenAdapter
/// @dev receives collateral from users and deposit in Vault.
contract MockCollateralTokenAdapter {
    address public collateralToken;

    constructor(address _collateralToken) {
        collateralToken = _collateralToken;
    }

    /// @dev Withdraw collateralToken from Vault
    /// @param _usr The address that holding states of the position
    /// @param _amount The collateralToken amount in Vault to be returned to proxyWallet and then to user
    function withdraw(address _usr, uint256 _amount, bytes calldata /* _data */) external {
        IToken(collateralToken).transfer(_usr, _amount);
    }
}

// SPDX-License-Identifier: MIT
// Original Copyright OpenZeppelin Contracts (last updated v4.5.0) (token/ERC20/extensions/ERC20Shares.sol)
// Copyright Fathom 2022

pragma solidity 0.8.16;

import "./ERC20Permit.sol";
import "./IShares.sol";
import "../../../common/math/Math.sol";
import "../../../common/cryptography/ECDSA.sol";
import "../../../common/math/SafeCast.sol";

abstract contract ERC20Shares is IShares, ERC20Permit {
    mapping(address => address) private _delegates;

    bytes32 private constant _DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    error InvalidNonce();
    error SignatureExpired();
    error BlockNotYetMined();
    error TotalSupplyOverflowsVotes();

    constructor(string memory name_, string memory symbol_) ERC20Permit(name_, symbol_) {}

    function delegate(address delegatee) external virtual override {
        _delegate(_msgSender(), delegatee);
    }

    function delegateBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s) external virtual override {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > expiry) {
            revert SignatureExpired();
        }
        address signer = ECDSA.recover(_hashTypedDataV4(keccak256(abi.encode(_DELEGATION_TYPEHASH, delegatee, nonce, expiry))), v, r, s);
        if (nonce != _useNonce(signer)) {
            revert InvalidNonce();
        }
        _delegate(signer, delegatee);
    }

    function delegates(address account) public view virtual override returns (address) {
        return _delegates[account];
    }

    function _mint(address account, uint256 amount) internal virtual override {
        super._mint(account, amount);
        if (totalSupply() > _maxSupply()) {
            revert TotalSupplyOverflowsVotes();
        }
    }

    function _delegate(address delegator, address delegatee) internal virtual {
        address currentDelegate = delegates(delegator);
        _delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);
    }

    function _maxSupply() internal view virtual returns (uint224) {
        return type(uint224).max;
    }

    function _add(uint256 a, uint256 b) private pure returns (uint256) {
        return a + b;
    }

    function _subtract(uint256 a, uint256 b) private pure returns (uint256) {
        return a - b;
    }
}

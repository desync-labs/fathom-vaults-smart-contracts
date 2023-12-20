// SPDX-License-Identifier: AGPL 3.0
// Copyright Fathom 2023

pragma solidity ^0.8.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./VaultStructs.sol";

contract VaultStorage {
    // CONSTANTS
    // The max length the withdrawal queue can be.
    uint256 public constant MAX_QUEUE = 10;
    // 100% in Basis Points.
    uint256 public constant MAX_BPS = 10000;
    // Extended for profit locking calculations.
    uint256 public constant MAX_BPS_EXTENDED = 1000000000000;
    // The version of this vault.
    string public constant API_VERSION = "1.0.0";
    uint256 public immutable ONE_YEAR = 31556952;

    address public strategyManager;
    address public sharesManager;
    address public setters;
    address public governance;

    // STORAGE
    // HashMap that records all the strategies that are allowed to receive assets from the vault.
    mapping(address => StrategyParams) public strategies;

    // The current fees
    FeeAssessment public fees;

    // The current default withdrawal queue.
    address[] public defaultQueue;

    // Should the vault use the default_queue regardless whats passed in.
    bool public useDefaultQueue;
    bool initialized;

    // ERC20 - amount of shares per account
    mapping(address => uint256) internal _balanceOf;
    // ERC20 - owner -> (spender -> amount)
    mapping(address => mapping(address => uint256)) internal _allowance;
    // Mapping from function selectors to contract addresses
    mapping(bytes4 => address) public implementations;

    // Total amount of shares that are currently minted including those locked.
    // NOTE: To get the ERC20 compliant version use totalSupply().
    uint256 public totalSupplyAmount;

    // Total amount of assets that has been deposited in strategies.
    uint256 public totalDebtAmount;
    // Current assets held in the vault contract. Replacing balanceOf(this) to avoid price_per_share manipulation.
    uint256 public totalIdleAmount;
    // Minimum amount of assets that should be kept in the vault contract to allow for fast, cheap redeems.
    uint256 public minimumTotalIdle;
    // Maximum amount of tokens that the vault can accept. If totalAssets > deposit_limit, deposits will revert.
    uint256 public depositLimit;
    // Contract that charges fees and can give refunds.
    address public accountant;
    // Contract to control the deposit limit.
    address public depositLimitModule;
    // Contract to control the withdraw limit.
    address public withdrawLimitModule;

    // HashMap mapping addresses to their roles
    mapping(address => bytes32) public roles;
    // HashMap mapping roles to their permissioned state. If false, the role is not open to the public.
    mapping(bytes32 => bool) public openRoles;

    // Address that can add and remove roles to addresses.
    address public roleManager;
    // Temporary variable to store the address of the next role_manager until the role is accepted.
    address public futureRoleManager;

    // State of the vault - if set to true, only withdrawals will be available. It can't be reverted.
    bool public shutdown;
    // The amount of time profits will unlock over.
    uint256 public profitMaxUnlockTime;
    // The timestamp of when the current unlocking period ends.
    uint256 public fullProfitUnlockDate;
    // The per second rate at which profit will unlock.
    uint256 public profitUnlockingRate;
    // Last timestamp of the most recent profitable report.
    uint256 public lastProfitUpdate;

    // EIP-2612 permit() nonces and typehashes
    mapping(address => uint256) public nonces;
    bytes32 public constant DOMAIN_TYPE_HASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPE_HASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    // Roles
    bytes32 public constant ACCOUNTANT_MANAGER = keccak256("ACCOUNTANT_MANAGER");
    bytes32 public constant QUEUE_MANAGER = keccak256("QUEUE_MANAGER");
    bytes32 public constant DEPOSIT_LIMIT_MANAGER = keccak256("DEPOSIT_LIMIT_MANAGER");
    bytes32 public constant WITHDRAW_LIMIT_MANAGER = keccak256("WITHDRAW_LIMIT_MANAGER");
    bytes32 public constant MINIMUM_IDLE_MANAGER = keccak256("MINIMUM_IDLE_MANAGER");
    bytes32 public constant PROFIT_UNLOCK_MANAGER = keccak256("PROFIT_UNLOCK_MANAGER");
    bytes32 public constant ROLE_MANAGER = keccak256("ROLE_MANAGER");
    bytes32 public constant REPORTING_MANAGER = keccak256("REPORTING_MANAGER");
    bytes32 public constant DEBT_PURCHASER = keccak256("DEBT_PURCHASER");
    bytes32 public constant ADD_STRATEGY_MANAGER = keccak256("ADD_STRATEGY_MANAGER");
    bytes32 public constant REVOKE_STRATEGY_MANAGER = keccak256("REVOKE_STRATEGY_MANAGER");
    bytes32 public constant FORCE_REVOKE_MANAGER = keccak256("FORCE_REVOKE_MANAGER");
    bytes32 public constant MAX_DEBT_MANAGER = keccak256("MAX_DEBT_MANAGER");
    bytes32 public constant DEBT_MANAGER = keccak256("DEBT_MANAGER");
    bytes32 public constant EMERGENCY_MANAGER = keccak256("EMERGENCY_MANAGER");         
}
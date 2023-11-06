// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
@title Yearn V3 Vault
@notice The Yearn VaultV3 is designed as a non-opinionated system to distribute funds of 
depositors for a specific `asset` into different opportunities (aka Strategies)
and manage accounting in a robust way.
*/

// INTERFACES
interface IStrategy {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function asset() external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
}

interface IAccountant {
    function report(address strategy, uint256 gain, uint256 loss) external returns (uint256, uint256);
}

interface IDepositLimitModule {
    function availableDepositLimit(address receiver) external view returns (uint256);
}

interface IWithdrawLimitModule {
    function availableWithdrawLimit(address owner, uint256 maxLoss, address[] calldata strategies) external returns (uint256);
}

interface IFactory {
    function protocolFeeConfig() external view returns (uint16, address);
}

// Solidity version of the Vyper contract
contract YearnV3Vault is IERC20, IERC20Metadata {
    using SafeMath for uint256;
    using Math for uint256;

    // STRUCTS
    struct StrategyParams {
        // Timestamp when the strategy was added.
        uint256 activation;
        // Timestamp of the strategies last report.
        uint256 lastReport;
        // The current assets the strategy holds.
        uint256 currentDebt;
        // The max assets the strategy can hold.
        uint256 maxDebt;
    }

    // ENUMS
    // Each permissioned function has its own Role.
    // Roles can be combined in any combination or all kept separate.
    // Follows python Enum patterns so the first Enum == 1 and doubles each time.
    enum Roles {
            ADD_STRATEGY_MANAGER, // Can add strategies to the vault.
            REVOKE_STRATEGY_MANAGER, // Can remove strategies from the vault.
            FORCE_REVOKE_MANAGER, // Can force remove a strategy causing a loss.
            ACCOUNTANT_MANAGER, // Can set the accountant that assess fees.
            QUEUE_MANAGER, // Can set the default withdrawal queue.
            REPORTING_MANAGER, // Calls report for strategies.
            DEBT_MANAGER, // Adds and removes debt from strategies.
            MAX_DEBT_MANAGER, // Can set the max debt for a strategy.
            DEPOSIT_LIMIT_MANAGER, // Sets deposit limit and module for the vault.
            WITHDRAW_LIMIT_MANAGER, // Sets the withdraw limit module.
            MINIMUM_IDLE_MANAGER, // Sets the minimum total idle the vault should keep.
            PROFIT_UNLOCK_MANAGER, // Sets the profit_max_unlock_time.
            DEBT_PURCHASER, // Can purchase bad debt from the vault.
            EMERGENCY_MANAGER // Can shutdown vault in an emergency.
        }

    enum StrategyChangeType {
        ADDED, // Corresponds to the strategy being added.
        REVOKED // Corresponds to the strategy being revoked.
    }

    enum Rounding {
        ROUND_DOWN, // Corresponds to rounding down to the nearest whole number.
        ROUND_UP // Corresponds to rounding up to the nearest whole number.
    }

    enum RoleStatusChange {
        OPENED, // Corresponds to a role being opened.
        CLOSED // Corresponds to a role being closed.
    }

    // CONSTANTS
    // The max length the withdrawal queue can be.
    uint256 public constant MAX_QUEUE = 10;
    // 100% in Basis Points.
    uint256 public constant MAX_BPS = 10000;
    // Extended for profit locking calculations.
    uint256 public constant MAX_BPS_EXTENDED = 1000000000000;
    // The version of this vault.
    string public constant API_VERSION = "3.0.1";

    // IMMUTABLE
    // Address of the underlying token used by the vault
    IERC20 public immutable ASSET;
    // Token decimals
    uint256 public immutable DECIMALS;
    // Factory address
    address public immutable FACTORY;

    // STORAGE
    // HashMap that records all the strategies that are allowed to receive assets from the vault.
    mapping(address => StrategyParams) public strategies;

    // The current default withdrawal queue.
    address[MAX_QUEUE] public defaultQueue;

    // Should the vault use the default_queue regardless whats passed in.
    bool public useDefaultQueue;

    // ERC20 - amount of shares per account
    mapping(address => uint256) private balanceOf;
    // ERC20 - owner -> (spender -> amount)
    mapping(address => mapping(address => uint256)) private allowance;

    // Total amount of shares that are currently minted including those locked.
    // NOTE: To get the ERC20 compliant version use totalSupply().
    uint256 public totalSupply;

    // Total amount of assets that has been deposited in strategies.
    uint256 public totalDebt;
    // Current assets held in the vault contract. Replacing balanceOf(this) to avoid price_per_share manipulation.
    uint256 public totalIdle;
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
    mapping(address => Roles) public roles;
    // HashMap mapping roles to their permissioned state. If false, the role is not open to the public.
    mapping(Roles => bool) public openRoles;

    // Address that can add and remove roles to addresses.
    address public roleManager;
    // Temporary variable to store the address of the next role_manager until the role is accepted.
    address public futureRoleManager;

    // ERC20 - name of the vault's token
    string public override name;
    // ERC20 - symbol of the vault's token
    string public override symbol;

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


    // EVENTS
    // ERC4626 EVENTS
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    // STRATEGY EVENTS
    event StrategyChanged(address indexed strategy, StrategyChangeType indexed changeType, uint256 value);
    event StrategyReported(
        address indexed strategy, 
        uint256 gain, 
        uint256 loss, 
        uint256 currentDebt, 
        uint256 protocolFees, 
        uint256 totalFees, 
        uint256 totalRefunds);

    // DEBT MANAGEMENT EVENTS
    event DebtUpdated(address indexed strategy, uint256 currentDebt, uint256 newDebt);

    // ROLE UPDATES
    event RoleSet(address indexed account, Roles indexed role);
    event RoleStatusChanged(Roles indexed role, RoleStatusChange indexed status);

    // STORAGE MANAGEMENT EVENTS
    event UpdateRoleManager(address indexed roleRanager);
    event UpdateAccountant(address indexed accountant);
    event UpdateDepositLimitModule(address indexed depositLimitModule);
    event UpdateWithdrawLimitModule(address indexed withdrawLimitModule);
    event UpdateDefaultQueue(address[] newDefaultQueue);
    event UpdateUseDefaultQueue(bool useDefaultQueue);
    event UpdatedMaxDebtForStrategy(address indexed sender, address indexed strategy, uint256 newDebt);
    event UpdateDepositLimit(uint256 depositLimit);
    event UpdateMinimumTotalIdle(uint256 minimumTotalIdle);
    event UpdateProfitMaxUnlockTime(uint256 profitMaxUnlockTime);
    event DebtPurchased(address indexed strategy, uint256 amount);
    event Shutdown();


    // Constructor
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _roleManager,
        uint256 _profitMaxUnlockTime
    ) {
        ASSET = _asset;
        DECIMALS = IERC20Metadata(address(_asset)).decimals();
        require(DECIMALS < 256, "Vault: invalid asset decimals");

        FACTORY = msg.sender;
        // Must be less than one year for report cycles
        require(_profitMaxUnlockTime <= 31556952, "Vault: profit unlock time too long");
        profitMaxUnlockTime = _profitMaxUnlockTime;

        name = _name;
        symbol = _symbol;
        roleManager = _roleManager;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPE_HASH,
                keccak256(bytes(_name)), // "Yearn Vault" in the example
                keccak256(bytes(API_VERSION)), // API_VERSION in the example
                block.chainid, // Current chain ID
                address(this) // Address of the contract
            )
        );
    }

    // SHARE MANAGEMENT
    // ERC20
    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        // Unlimited approval does nothing (saves an SSTORE)
        uint256 currentAllowance = allowance[owner][spender];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _approve(owner, spender, currentAllowance.sub(amount));
    }

    function _transfer(address sender, address receiver, uint256 amount) internal {
        uint256 currentBalance = balanceOf[sender];
        require(currentBalance >= amount, "insufficient funds");
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(receiver != address(0), "ERC20: transfer to the zero address");

        balanceOf[sender] = currentBalance.sub(amount);
        uint256 receiverBalance = balanceOf[receiver];
        balanceOf[receiver] = receiverBalance.add(amount);
        emit Transfer(sender, receiver, amount);
    }

    function _transferFrom(address sender, address receiver, uint256 amount) internal {
        _spendAllowance(sender, msg.sender, amount);
        _transfer(sender, receiver, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _increaseAllowance(address owner, address spender, uint256 amount) internal {
        uint256 newAllowance = allowance[owner][spender].add(amount);
        _approve(owner, spender, newAllowance);
    }

    function _decreaseAllowance(address owner, address spender, uint256 amount) internal {
        uint256 newAllowance = allowance[owner][spender].sub(amount);
        _approve(owner, spender, newAllowance);
    }

    function _permit(
        address owner, 
        address spender, 
        uint256 amount, 
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) internal {
        require(owner != address(0), "ERC20Permit: invalid owner");
        require(deadline >= block.timestamp, "ERC20Permit: expired deadline");
        uint256 nonce = nonces[owner];

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPE_HASH, owner, spender, amount, nonce, deadline));

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                structHash
            )
        );

        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, "ERC20Permit: invalid signature");
        
        // Set the allowance to the specified amount
        _approve(owner, spender, amount);

        // Increase nonce for the owner
        nonces[owner]++;

        emit Approval(owner, spender, amount);
    }

    function _burnShares(uint256 shares, address owner) internal {
        require(balanceOf[owner] >= shares, "Insufficient shares");
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        emit Transfer(owner, address(0), shares);
    }

    // Returns the amount of shares that have been unlocked.
    // To avoid sudden pricePerShare spikes, profits must be processed 
    // through an unlocking period. The mechanism involves shares to be 
    // minted to the vault which are unlocked gradually over time. Shares 
    // that have been locked are gradually unlocked over profitMaxUnlockTime.
    function _unlockedShares() internal view returns (uint256) {
        uint256 _fullProfitUnlockDate = fullProfitUnlockDate;
        uint256 unlockedShares = 0;
        if (_fullProfitUnlockDate > block.timestamp) {
            // If we have not fully unlocked, we need to calculate how much has been.
            unlockedShares = profitUnlockingRate * (block.timestamp - lastProfitUpdate) / MAX_BPS_EXTENDED;
        } else if (_fullProfitUnlockDate != 0) {
            // All shares have been unlocked
            unlockedShares = balanceOf[address(this)];
        }
        return unlockedShares;
    }
    
    // Need to account for the shares issued to the vault that have unlocked.
    function _totalSupply() internal view returns (uint256) {
        uint256 unlockedShares = _unlockedShares();
        return totalSupply - unlockedShares;
    }

    // Burns shares that have been unlocked since last update. 
    // In case the full unlocking period has passed, it stops the unlocking.
    function _burnUnlockedShares() internal {
        // Get the amount of shares that have unlocked
        uint256 unlockedShares = _unlockedShares();
        // IF 0 there's nothing to do.
        if (unlockedShares == 0) return;
        
        // Only do an SSTORE if necessary
        if (fullProfitUnlockDate > block.timestamp) {
            lastProfitUpdate = block.timestamp;
        }
        
        // Burn the shares unlocked.
        _burnShares(unlockedShares, address(this));
    }

    // Total amount of assets that are in the vault and in the strategies.
    function _totalAssets() internal view returns (uint256) {
        return totalIdle + totalDebt;
    }

    // assets = shares * (total_assets / total_supply) --- (== price_per_share * shares)
    function _convertToAssets(uint256 shares, Rounding rounding) internal view returns (uint256) {
        if (shares == type(uint256).max || shares == 0) {
            return shares;
        }

        uint256 currentTotalSupply = _totalSupply();
        // if total_supply is 0, price_per_share is 1
        if (currentTotalSupply == 0) {
            return shares;
        }

        uint256 totalAssets = _totalAssets();
        uint256 numerator = shares * totalAssets;
        uint256 amount = numerator / currentTotalSupply;
        if (rounding == Rounding.ROUND_UP && numerator % currentTotalSupply != 0) {
            amount += 1;
        }

        return amount;
    }

    // shares = amount * (total_supply / total_assets) --- (== amount / price_per_share)
    function _convertToShares(uint256 assets, Rounding rounding) internal view returns (uint256) {
        if (assets == type(uint256).max || assets == 0) {
            return assets;
        }

        uint256 currentTotalSupply = _totalSupply();
        uint256 currentTotalAssets = _totalAssets();
        
        if (currentTotalAssets == 0) {
            // if total_assets and total_supply is 0, price_per_share is 1
            if (currentTotalSupply == 0) {
                return assets;
            } else {
                // Else if total_supply > 0 price_per_share is 0
                return 0;
            }
        }

        uint256 numerator = assets * currentTotalSupply;
        uint256 shares = numerator / currentTotalAssets;
        if (rounding == Rounding.ROUND_UP && numerator % currentTotalAssets != 0) {
            shares += 1;
        }

        return shares;
    }

    // Used only to approve tokens that are not the type managed by this Vault.
    // Used to handle non-compliant tokens like USDT
    function _erc20SafeApprove(address token, address spender, uint256 amount) internal {
        require(token != address(0), "Token address cannot be zero");
        require(spender != address(0), "Spender address cannot be zero");
        bool success = IERC20(token).approve(spender, amount);
        require(success, "approval failed");
    }

    // Used only to transfer tokens that are not the type managed by this Vault.
    // Used to handle non-compliant tokens like USDT
    function _erc20SafeTransferFrom(address token, address sender, address receiver, uint256 amount) internal {
        require(token != address(0), "Token address cannot be zero");
        require(sender != address(0), "Sender address cannot be zero");
        require(receiver != address(0), "Receiver address cannot be zero");
        bool success = IERC20(token).transferFrom(sender, receiver, amount);
        require(success, "transfer failed");
    }

    // Used only to send tokens that are not the type managed by this Vault.
    // Used to handle non-compliant tokens like USDT
    function _erc20SafeTransfer(address token, address receiver, uint256 amount) internal {
        require(token != address(0), "Token address cannot be zero");
        require(receiver != address(0), "Receiver address cannot be zero");
        bool success = IERC20(token).transfer(receiver, amount);
        require(success, "transfer failed");
    }

    function _issueShares(uint256 shares, address recipient) internal {
        require(recipient != address(0), "Recipient address cannot be zero");
        balanceOf[recipient] += shares;
        totalSupply += shares;
        emit Transfer(address(0), recipient, shares);
    }

    // Issues shares that are worth 'amount' in the underlying token (asset).
    // WARNING: this takes into account that any new assets have been summed 
    // to total_assets (otherwise pps will go down).
    function _issueSharesForAmount(uint256 amount, address recipient) internal returns (uint256) {
        require(recipient != address(0), "Recipient address cannot be zero");
        uint256 currentTotalSupply = _totalSupply();
        uint256 totalAssets = _totalAssets();
        uint256 newShares = 0;

        // If no supply PPS = 1.
        if (currentTotalSupply == 0) {
            newShares = amount;
        } else if (totalAssets > amount) {
            newShares = amount * currentTotalSupply / (totalAssets - amount);
        } else {
            // If total_supply > 0 but amount = totalAssets we want to revert because
            // after first deposit, getting here would mean that the rest of the shares
            // would be diluted to a price_per_share of 0. Issuing shares would then mean
            // either the new depositor or the previous depositors will loose money.
            revert("amount too high");
        }

        // We don't make the function revert
        if (newShares == 0) {
            return 0;
        }

        _issueShares(newShares, recipient);
        return newShares;
    }


    // ERC4626
    function _maxDeposit(address receiver) internal view returns (uint256) {
        if (receiver == address(this) || receiver == address(0)) {
            return 0;
        }

        // If there is a deposit limit module set use that.
        address currentDepositLimitModule = depositLimitModule;
        if (currentDepositLimitModule != address(0)) {
            // Use the deposit limit module logic
            return IDepositLimitModule(currentDepositLimitModule).availableDepositLimit(receiver);
        }

        // Else use the standard flow.
        uint256 totalAssets = _totalAssets();
        uint256 currentDepositLimit = depositLimit;
        if (totalAssets >= currentDepositLimit) {
            return 0;
        }

        return currentDepositLimit - totalAssets;
    }

    // @dev Returns the max amount of `asset` an `owner` can withdraw.

    // This will do a full simulation of the withdraw in order to determine
    // how much is currently liquid and if the `max_loss` would allow for the 
    // tx to not revert.

    // This will track any expected loss to check if the tx will revert, but
    // not account for it in the amount returned since it is unrealised and 
    // therefore will not be accounted for in the conversion rates.

    // i.e. If we have 100 debt and 10 of unrealised loss, the max we can get
    // out is 90, but a user of the vault will need to call withdraw with 100
    // in order to get the full 90 out.
    function _maxWithdraw(address owner, uint256 _maxLoss, address[MAX_QUEUE] memory _strategies)
        internal
        view
        returns (uint256)
    {
        // Get the max amount for the owner if fully liquid.
        uint256 maxAssets = _convertToAssets(balanceOf[owner], Rounding.ROUND_DOWN);

        // If there is a withdraw limit module use that.
        if (withdrawLimitModule != address(0)) {
            uint256 moduleLimit = IWithdrawLimitModule(withdrawLimitModule).availableWithdrawLimit(owner, _maxLoss, _strategies);
            if (moduleLimit < maxAssets) {
                maxAssets = moduleLimit;
            }
            return maxAssets;
        }

        // See if we have enough idle to service the withdraw.
        uint256 currentIdle = totalIdle;
        if (maxAssets > currentIdle) {
            // Track how much we can pull.
            uint256 have = currentIdle;
            uint256 loss = 0;
            
            // Cache the default queue.
            // If a custom queue was passed, and we don't force the default queue.
            // Use the custom queue.
            address[MAX_QUEUE] memory currentStrategies = _strategies.length != 0 && !useDefaultQueue ? _strategies : defaultQueue;

            for (uint256 i = 0; i < currentStrategies.length; i++) {
                address strategy = currentStrategies[i];
                // Can't use an invalid strategy.
                require(strategies[strategy].activation != 0, "inactive strategy");

                // Get the maximum amount the vault would withdraw from the strategy.
                uint256 toWithdraw = Math.min(
                    maxAssets - have, // What we still need for the full withdraw
                    strategies[strategy].currentDebt // The current debt the strategy has.
                    );

                // Get any unrealised loss for the strategy.
                uint256 unrealisedLoss = _assessShareOfUnrealisedLosses(strategy, toWithdraw);

                // See if any limit is enforced by the strategy.
                uint256 strategyLimit = IStrategy(strategy).convertToAssets(
                    IStrategy(strategy).maxRedeem(address(this))
                );

                // Adjust accordingly if there is a max withdraw limit.
                if (strategyLimit < toWithdraw - unrealisedLoss) {
                    // lower unrealised loss to the proportional to the limit.
                    unrealisedLoss = (unrealisedLoss * strategyLimit) / toWithdraw;
                    // Still count the unrealised loss as withdrawable.
                    toWithdraw = strategyLimit + unrealisedLoss;
                }

                // If 0 move on to the next strategy.
                if (toWithdraw == 0) {
                    continue;
                }

                // If there would be a loss with a non-maximum `max_loss` value.
                if (unrealisedLoss > 0 && _maxLoss < MAX_BPS) {
                    // Check if the loss is greater than the allowed range.
                    if (loss + unrealisedLoss > (have + toWithdraw) * _maxLoss / MAX_BPS) {
                        // If so use the amounts up till now.
                        break;
                    }
                }

                // Add to what we can pull.
                have += toWithdraw;

                // If we have all we need break.
                if (have >= maxAssets) {
                    break;
                }

                // Add any unrealised loss to the total
                loss += unrealisedLoss;
            }

            // Update the max after going through the queue.
            // In case we broke early or exhausted the queue.
            maxAssets = have;
        }

        return maxAssets;
    }
}

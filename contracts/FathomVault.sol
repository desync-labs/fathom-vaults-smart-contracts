// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "./Interfaces/IVault.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./VaultStorage.sol";
import "./Interfaces/IVaultEvents.sol";
import "./Interfaces/IAccountant.sol";
import "./Interfaces/IStrategy.sol";
import "./Interfaces/IDepositLimitModule.sol";
import "./Interfaces/IWithdrawLimitModule.sol";
import "./Interfaces/IFactory.sol";
import "./Interfaces/IStrategyManager.sol";

/**
@title Yearn V3 Vault
@notice The Yearn VaultV3 is designed as a non-opinionated system to distribute funds of 
depositors for a specific `asset` into different opportunities (aka Strategies)
and manage accounting in a robust way.
*/

// Solidity version of the Vyper contract
contract FathomVault is IERC20, IERC20Metadata, AccessControl, IVault, ReentrancyGuard, VaultStorage, IVaultEvents {
    // solhint-disable not-rely-on-time
    // solhint-disable function-max-lines
    // solhint-disable code-complexity
    // solhint-disable var-name-mixedcase

    using Math for uint256;

    error InvalidAssetDecimals();
    error ProfitUnlockTimeTooLong();
    error ERC20InsufficientAllowance();
    error InsufficientFunds();
    error ZeroAddress();
    error ERC20PermitExpired();
    error ERC20PermitInvalidSignature();
    error InsufficientShares();
    error InactiveStrategy();
    error StrategyIsShutdown();
    error ExceedDepositLimit();
    error ZeroValue();
    error MaxLoss();
    error InsufficientAssets();
    error TooMuchLoss();
    error InvalidAsset();
    error StrategyAlreadyActive();
    error StrategyHasDebt();
    error DebtDidntChange();
    error StrategyHasUnrealisedLosses();
    error DebtHigherThanMaxDebt();
    error UsingModule();
    error UsingDepositLimit();
    error CallerIsNotTheFutureRoleManager();
    error StrategyDebtIsLessThanAssetsNeeded();

    // ERC20 - name of the vault's token
    string public override name;
    // ERC20 - symbol of the vault's token
    string public override symbol;

    // IMMUTABLE
    // Address of the underlying token used by the vault
    IERC20 public immutable ASSET;
    // Token decimals
    uint8 public immutable DECIMALS;
    // Factory address
    address public immutable FACTORY;
    uint256 public immutable ONE_YEAR = 31556952;

    // Constructor
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _roleManager,
        uint256 _profitMaxUnlockTime,
        address _strategyManagerAddress
    ) {
        ASSET = IERC20(_asset);
        DECIMALS = _decimals;
        if (DECIMALS >= 256) {
            revert InvalidAssetDecimals();
        }

        FACTORY = msg.sender;
        // Must be less than one year for report cycles
        if (_profitMaxUnlockTime > ONE_YEAR) {
            revert ProfitUnlockTimeTooLong();
        }

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

        strategyManager = _strategyManagerAddress;
    }

    // SHARE MANAGEMENT
    // ERC20
    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        // Unlimited approval does nothing (saves an SSTORE)
        uint256 currentAllowance = _allowance[owner][spender];
        if (currentAllowance < amount) {
            revert ERC20InsufficientAllowance();
        }
        _approve(owner, spender, currentAllowance - amount);
    }

    function _transfer(address sender, address receiver, uint256 amount) internal {
        uint256 currentBalance = _balanceOf[sender];
        if (currentBalance < amount) {
            revert InsufficientFunds();
        }
        if (sender == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }

        _balanceOf[sender] = currentBalance - amount;
        uint256 receiverBalance = _balanceOf[receiver];
        _balanceOf[receiver] = receiverBalance + amount;
        emit Transfer(sender, receiver, amount);
    }

    function _transferFrom(address sender, address receiver, uint256 amount) internal returns (bool) {
        _spendAllowance(sender, msg.sender, amount);
        _transfer(sender, receiver, amount);
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) internal returns (bool) {
        if (owner == address(0) || spender == address(0)) {
            revert ZeroAddress();
        }
        _allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
        return true;
    }

    function _increaseAllowance(address owner, address spender, uint256 amount) internal returns (bool) {
        uint256 newAllowance = _allowance[owner][spender] + amount;
        _approve(owner, spender, newAllowance);
        return true;
    }

    function _decreaseAllowance(address owner, address spender, uint256 amount) internal returns (bool) {
        uint256 newAllowance = _allowance[owner][spender] - amount;
        _approve(owner, spender, newAllowance);
        return true;
    }

    function _permit(
        address owner, 
        address spender, 
        uint256 amount, 
        uint256 deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) internal returns (bool) {
        if (owner == address(0)) {
            revert ZeroAddress();
        }
        if (deadline < block.timestamp) {
            revert ERC20PermitExpired();
        }
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
        if (recoveredAddress == address(0) || recoveredAddress != owner) {
            revert ERC20PermitInvalidSignature();
        }
        
        // Set the allowance to the specified amount
        _approve(owner, spender, amount);

        // Increase nonce for the owner
        nonces[owner]++;

        emit Approval(owner, spender, amount);
        return true;
    }

    function _burnShares(uint256 shares, address owner) internal {
        if (_balanceOf[owner] < shares) {
            revert InsufficientShares();
        }
        _balanceOf[owner] -= shares;
        totalSupplyAmount -= shares;
        emit Transfer(owner, address(0), shares);
    }

    // Returns the amount of shares that have been unlocked.
    // To avoid sudden pricePerShare spikes, profits must be processed 
    // through an unlocking period. The mechanism involves shares to be 
    // minted to the vault which are unlocked gradually over time. Shares 
    // that have been locked are gradually unlocked over profitMaxUnlockTime.
    function _unlockedShares() internal view returns (uint256) {
        uint256 _fullProfitUnlockDate = fullProfitUnlockDate;
        uint256 currUnlockedShares = 0;
        if (_fullProfitUnlockDate > block.timestamp) {
            // If we have not fully unlocked, we need to calculate how much has been.
            currUnlockedShares = profitUnlockingRate * (block.timestamp - lastProfitUpdate) / MAX_BPS_EXTENDED;
        } else if (_fullProfitUnlockDate != 0) {
            // All shares have been unlocked
            currUnlockedShares = _balanceOf[address(this)];
        }
        return currUnlockedShares;
    }
    
    // Need to account for the shares issued to the vault that have unlocked.
    function _totalSupply() internal view returns (uint256) {
        return totalSupplyAmount - _unlockedShares();
    }

    // Burns shares that have been unlocked since last update. 
    // In case the full unlocking period has passed, it stops the unlocking.
    function _burnUnlockedShares() internal {
        // Get the amount of shares that have unlocked
        uint256 currUnlockedShares = _unlockedShares();
        // IF 0 there's nothing to do.
        if (currUnlockedShares == 0) return;
        
        // Only do an SSTORE if necessary
        if (fullProfitUnlockDate > block.timestamp) {
            lastProfitUpdate = block.timestamp;
        }
        
        // Burn the shares unlocked.
        _burnShares(currUnlockedShares, address(this));
    }

    // Total amount of assets that are in the vault and in the strategies.
    function _totalAssets() internal view returns (uint256) {
        return totalIdleAmount + totalDebtAmount;
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

        uint256 numerator = shares * _totalAssets();
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
        if (token == address(0) || spender == address(0)) {
            revert ZeroAddress();
        }
        require(IERC20(token).approve(spender, amount), "approval failed");
    }

    // Used only to transfer tokens that are not the type managed by this Vault.
    // Used to handle non-compliant tokens like USDT
    function _erc20SafeTransferFrom(address token, address sender, address receiver, uint256 amount) internal {
        if (token == address(0) || sender == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        require(IERC20(token).transferFrom(sender, receiver, amount), "transfer failed");
    }

    // Used only to send tokens that are not the type managed by this Vault.
    // Used to handle non-compliant tokens like USDT
    function _erc20SafeTransfer(address token, address receiver, uint256 amount) internal {
        if (token == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        require(IERC20(token).transfer(receiver, amount), "transfer failed");
    }

    function _issueShares(uint256 shares, address recipient) internal {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        _balanceOf[recipient] += shares;
        totalSupplyAmount += shares;
        emit Transfer(address(0), recipient, shares);
    }

    // Issues shares that are worth 'amount' in the underlying token (asset).
    // WARNING: this takes into account that any new assets have been summed 
    // to total_assets (otherwise pps will go down).
    function _issueSharesForAmount(uint256 amount, address recipient) internal returns (uint256) {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        uint256 currentTotalSupply = _totalSupply();
        uint256 currentTotalAssets = _totalAssets();
        uint256 newShares = 0;

        // If no supply PPS = 1.
        if (currentTotalSupply == 0) {
            newShares = amount;
        } else if (currentTotalAssets > amount) {
            newShares = amount * currentTotalSupply / (currentTotalAssets - amount);
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
        uint256 currentTotalAssets = _totalAssets();
        uint256 currentDepositLimit = depositLimit;
        if (currentTotalAssets >= currentDepositLimit) {
            return 0;
        }

        return currentDepositLimit - currentTotalAssets;
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
    function _maxWithdraw(address owner, uint256 _maxLoss, address[] memory _strategies)
        internal
        returns (uint256)
    {
        // Get the max amount for the owner if fully liquid.
        uint256 maxAssets = _convertToAssets(_balanceOf[owner], Rounding.ROUND_DOWN);

        // If there is a withdraw limit module use that.
        if (withdrawLimitModule != address(0)) {
            uint256 moduleLimit = IWithdrawLimitModule(withdrawLimitModule).availableWithdrawLimit(owner, _maxLoss, _strategies);
            if (moduleLimit < maxAssets) {
                maxAssets = moduleLimit;
            }
            return maxAssets;
        }

        // See if we have enough idle to service the withdraw.
        uint256 currentIdle = totalIdleAmount;
        if (maxAssets > currentIdle) {
            // Track how much we can pull.
            uint256 have = currentIdle;
            uint256 loss = 0;
            
            // Cache the default queue.
            // If a custom queue was passed, and we don't force the default queue.
            // Use the custom queue.
            address[] memory currentStrategies = _strategies.length != 0 && !useDefaultQueue ? _strategies : defaultQueue;

            for (uint256 i = 0; i < currentStrategies.length; i++) {
                address strategy = currentStrategies[i];
                // Can't use an invalid strategy.
                if (strategies[strategy].activation == 0) {
                    revert InactiveStrategy();
                }

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

    // Used for `deposit` calls to transfer the amount of `asset` to the vault, 
    // issue the corresponding shares to the `recipient` and update all needed 
    // vault accounting.
    function _deposit(address sender, address recipient, uint256 assets) internal returns (uint256) {
        if (shutdown == true) {
            revert StrategyIsShutdown();
        }
        if (assets > _maxDeposit(recipient)) {
            revert ExceedDepositLimit();
        }

        // Transfer the tokens to the vault first.
        ASSET.transferFrom(msg.sender, address(this), assets);
        // Record the change in total assets.
        totalIdleAmount += assets;

        // Issue the corresponding shares for assets.
        uint256 shares = _issueSharesForAmount(assets, recipient);
        if (shares < 0) {
            revert ZeroValue();
        }

        emit Deposit(sender, recipient, assets, shares);
        return shares;
    }

    // Used for `mint` calls to issue the corresponding shares to the `recipient`,
    // transfer the amount of `asset` to the vault, and update all needed vault 
    // accounting.
    function _mint(address sender, address recipient, uint256 shares) internal returns (uint256) {
        if (shutdown == true) {
            revert StrategyIsShutdown();
        }
        // Get corresponding amount of assets.
        uint256 assets = _convertToAssets(shares, Rounding.ROUND_UP);

        if (assets < 0) {
            revert ZeroValue();
        }
        if (assets > _maxDeposit(recipient)) {
            revert ExceedDepositLimit();
        }

        // Transfer the tokens to the vault first.
        ASSET.transferFrom(msg.sender, address(this), assets);
        // Record the change in total assets.
        totalIdleAmount += assets;

        // Issue the corresponding shares for assets.
        _issueShares(shares, recipient); // Assuming _issueShares is defined elsewhere

        emit Deposit(sender, recipient, assets, shares);
        return assets;
    }

    // Returns the share of losses that a user would take if withdrawing from this strategy
    // e.g. if the strategy has unrealised losses for 10% of its current debt and the user 
    // wants to withdraw 1000 tokens, the losses that he will take are 100 token
    function _assessShareOfUnrealisedLosses(address strategy, uint256 assetsNeeded) internal view returns (uint256) {
        // Minimum of how much debt the debt should be worth.
        uint256 strategyCurrentDebt = strategies[strategy].currentDebt;
        // The actual amount that the debt is currently worth.
        uint256 vaultShares = IStrategy(strategy).balanceOf(address(this));
        uint256 strategyAssets = IStrategy(strategy).convertToAssets(vaultShares);

        // If no losses, return 0
        if (strategyAssets >= strategyCurrentDebt || strategyCurrentDebt == 0) {
            return 0;
        }

        // Users will withdraw assets_to_withdraw divided by loss ratio (strategy_assets / strategy_current_debt - 1),
        // but will only receive assets_to_withdraw.
        // NOTE: If there are unrealised losses, the user will take his share.
        uint256 numerator = assetsNeeded * strategyAssets;
        uint256 lossesUserShare = assetsNeeded - numerator / strategyCurrentDebt;

        // Always round up.
        if (numerator % strategyCurrentDebt != 0) {
            lossesUserShare += 1;
        }

        return lossesUserShare;
    }

    // This takes the amount denominated in asset and performs a {redeem}
    // with the corresponding amount of shares.
    // We use {redeem} to natively take on losses without additional non-4626 standard parameters.
    function _withdrawFromStrategy(address strategy, uint256 assetsToWithdraw) internal {
        // Need to get shares since we use redeem to be able to take on losses.
        uint256 sharesToRedeem = Math.min(
            IStrategy(strategy).previewWithdraw(assetsToWithdraw), // Use previewWithdraw since it should round up.
            IStrategy(strategy).balanceOf(address(this)) // And check against our actual balance.
        );

        // Redeem the shares.
        IStrategy(strategy).redeem(sharesToRedeem, address(this), address(this));
    }

    // This will attempt to free up the full amount of assets equivalent to
    // `shares_to_burn` and transfer them to the `receiver`. If the vault does
    // not have enough idle funds it will go through any strategies provided by
    // either the withdrawer or the queue_manager to free up enough funds to 
    // service the request.

    // The vault will attempt to account for any unrealized losses taken on from
    // strategies since their respective last reports.

    // Any losses realized during the withdraw from a strategy will be passed on
    // to the user that is redeeming their vault shares.
    function _redeem(
        address sender,
        address receiver,
        address owner,
        uint256 assets,
        uint256 sharesToBurn,
        uint256 maxLoss,
        address[] memory _strategies
    ) internal returns (uint256) {
        _validateRedeem(receiver, owner, sharesToBurn, maxLoss);
        _handleAllowance(owner, sender, sharesToBurn);
        (uint256 requestedAssets, uint256 currTotalIdle) = _withdrawAssets(assets, _strategies);
        _finalizeRedeem(receiver, owner, sharesToBurn, assets, requestedAssets, currTotalIdle, maxLoss);
        
        emit Withdraw(sender, receiver, owner, requestedAssets, sharesToBurn);
        return requestedAssets;
    }

    // Validates the state and inputs for the redeem operation.
    function _validateRedeem(
        address receiver,
        address owner,
        uint256 sharesToBurn,
        uint256 maxLoss
    ) internal view {
        if (receiver == address(0)) {
            revert ZeroAddress();
        }
        if (maxLoss > MAX_BPS) {
            revert MaxLoss();
        }
        if (sharesToBurn <= 0) {
            revert ZeroValue();
        }
        if (_balanceOf[owner] < sharesToBurn) {
            revert InsufficientShares();
        }
    }

    // Handles the allowance check and spending.
    function _handleAllowance(address owner, address sender, uint256 sharesToBurn) internal {
        if (sender != owner) {
            _spendAllowance(owner, sender, sharesToBurn);
        }
    }

    // Withdraws assets from strategies as needed and handles unrealized losses.
    function _withdrawAssets(uint256 assets, address[] memory _strategies) internal returns (uint256, uint256) {
        // Initialize the state struct
        WithdrawalState memory state = WithdrawalState({
            requestedAssets: assets,
            currTotalIdle: totalIdleAmount,
            currTotalDebt: totalDebtAmount,
            assetsNeeded: 0,
            previousBalance: ASSET.balanceOf(address(this)),
            unrealisedLossesShare: 0
        });

        // If there are not enough assets in the Vault contract, we try to free
        // funds from strategies.
        if (state.requestedAssets > state.currTotalIdle) {
            // Cache the default queue.
            address[] memory currentStrategies = _strategies.length != 0 && !useDefaultQueue ? _strategies : defaultQueue;

            // Withdraw from strategies only what idle doesn't cover.
            // `assetsNeeded` is the total amount we need to fill the request.
            state.assetsNeeded = state.requestedAssets - state.currTotalIdle;

            // Assuming _strategies is an array of addresses representing the strategies
            for (uint i = 0; i < currentStrategies.length; i++) {
                address strategy = currentStrategies[i];
                
                // Make sure we have a valid strategy.
                if (strategies[strategy].activation == 0) {
                    revert InactiveStrategy();
                }

                // How much should the strategy have.
                uint256 currentDebt = strategies[strategy].currentDebt;

                // What is the max amount to withdraw from this strategy.
                uint256 assetsToWithdraw = Math.min(state.assetsNeeded, currentDebt);

                // Cache max_withdraw now for use if unrealized loss > 0
                // Use maxRedeem and convert since we use redeem.
                uint256 currMaxWithdraw = IStrategy(strategy).convertToAssets(
                    IStrategy(strategy).maxRedeem(address(this))
                );

                // CHECK FOR UNREALIZED LOSSES
                // If unrealised losses > 0, then the user will take the proportional share 
                // and realize it (required to avoid users withdrawing from lossy strategies).
                // NOTE: strategies need to manage the fact that realising part of the loss can 
                // mean the realisation of 100% of the loss!! (i.e. if for withdrawing 10% of the
                // strategy it needs to unwind the whole position, generated losses might be bigger)
                uint256 unrealisedLossesShare = _assessShareOfUnrealisedLosses(strategy, assetsToWithdraw);
                if (unrealisedLossesShare > 0) {
                    // If max withdraw is limiting the amount to pull, we need to adjust the portion of 
                    // the unrealized loss the user should take.
                    if (currMaxWithdraw < assetsToWithdraw - unrealisedLossesShare) {
                        // How much would we want to withdraw
                        uint256 wanted = assetsToWithdraw - unrealisedLossesShare;
                        // Get the proportion of unrealised comparing what we want vs. what we can get
                        unrealisedLossesShare = unrealisedLossesShare * currMaxWithdraw / wanted;
                        // Adjust assetsToWithdraw so all future calculations work correctly
                        assetsToWithdraw = currMaxWithdraw + unrealisedLossesShare;
                    }
                    
                    // User now "needs" less assets to be unlocked (as he took some as losses)
                    assetsToWithdraw -= unrealisedLossesShare;
                    state.requestedAssets -= unrealisedLossesShare;
                    // NOTE: done here instead of waiting for regular update of these values 
                    // because it's a rare case (so we can save minor amounts of gas)
                    state.assetsNeeded -= unrealisedLossesShare;
                    state.currTotalDebt -= unrealisedLossesShare;

                    // If max withdraw is 0 and unrealised loss is still > 0 then the strategy likely
                    // realized a 100% loss and we will need to realize that loss before moving on.
                    if (currMaxWithdraw == 0 && unrealisedLossesShare > 0) {
                        // Adjust the strategy debt accordingly.
                        uint256 newDebt = currentDebt - unrealisedLossesShare;

                        // Update strategies storage
                        strategies[strategy].currentDebt = newDebt;

                        // Log the debt update
                        emit DebtUpdated(strategy, currentDebt, newDebt);
                    }
                }

                // Adjust based on the max withdraw of the strategy.
                assetsToWithdraw = Math.min(assetsToWithdraw, currMaxWithdraw);

                // Can't withdraw 0.
                if (assetsToWithdraw == 0) {
                    continue;
                }

                // WITHDRAW FROM STRATEGY
                _withdrawFromStrategy(strategy, assetsToWithdraw);
                uint256 postBalance = ASSET.balanceOf(address(this));
                
                // Always check withdrawn against the real amounts.
                uint256 withdrawn = postBalance - state.previousBalance;
                uint256 loss = 0;
                // Check if we redeemed too much.
                if (withdrawn > assetsToWithdraw) {
                    // Make sure we don't underflow in debt updates.
                    if (withdrawn > currentDebt) {
                        // Can't withdraw more than our debt.
                        assetsToWithdraw = currentDebt;
                    } else {
                        assetsToWithdraw += withdrawn - assetsToWithdraw;
                    }
                // If we have not received what we expected, we consider the difference a loss.
                } else if (withdrawn < assetsToWithdraw) {
                    loss = assetsToWithdraw - withdrawn;
                }

                // NOTE: strategy's debt decreases by the full amount but the total idle increases 
                // by the actual amount only (as the difference is considered lost).
                state.currTotalIdle += assetsToWithdraw - loss;
                state.requestedAssets -= loss;
                state.currTotalDebt -= assetsToWithdraw;

                // Vault will reduce debt because the unrealised loss has been taken by user
                uint256 _newDebt = currentDebt - (assetsToWithdraw + unrealisedLossesShare);

                // Update strategies storage
                strategies[strategy].currentDebt = _newDebt;
                // Log the debt update
                emit DebtUpdated(strategy, currentDebt, _newDebt);

                // Break if we have enough total idle to serve initial request.
                if (state.requestedAssets <= state.currTotalIdle) {
                    break;
                }

                // We update the previous_balance variable here to save gas in next iteration.
                state.previousBalance = postBalance;

                // Reduce what we still need. Safe to use assets_to_withdraw 
                // here since it has been checked against requested_assets
                state.assetsNeeded -= assetsToWithdraw;
            }

            // If we exhaust the queue and still have insufficient total idle, revert.
            if (state.currTotalIdle < state.requestedAssets) {
                revert InsufficientAssets();
            }

            // Commit memory to storage.
            totalDebtAmount = state.currTotalDebt;
        }

        return (state.requestedAssets, state.currTotalIdle);
    }

    // Finalizes the redeem operation by burning shares and transferring assets.
    function _finalizeRedeem(
        address receiver,
        address owner,
        uint256 sharesToBurn,
        uint256 assets,
        uint256 requestedAssets,
        uint256 currTotalIdle,
        uint256 maxLoss
    ) internal {
        // Check if there is a loss and a non-default value was set.
        if (assets > requestedAssets && maxLoss < MAX_BPS) {
            // Assure the loss is within the allowed range.
            if (assets - requestedAssets > assets * maxLoss / MAX_BPS) {
                revert TooMuchLoss();
            }
        }

        // First burn the corresponding shares from the redeemer.
        _burnShares(sharesToBurn, owner);
        // Commit memory to storage.
        totalIdleAmount = currTotalIdle - requestedAssets;
        // Transfer the requested amount to the receiver.
        _erc20SafeTransfer(address(ASSET), receiver, requestedAssets);
    }

    // STRATEGY MANAGEMENT
    function _addStrategy(address newStrategy) internal {
        // Delegate call to StrategyManager
        IStrategyManager(strategyManager).addStrategy(newStrategy);
    }

    function _revokeStrategy(address strategy, bool force) internal {
        // Delegate call to StrategyManager
        IStrategyManager(strategyManager).revokeStrategy(strategy, force);
    }

    // DEBT MANAGEMENT
    // The vault will re-balance the debt vs target debt. Target debt must be
    // smaller or equal to strategy's max_debt. This function will compare the 
    // current debt with the target debt and will take funds or deposit new 
    // funds to the strategy. 

    // The strategy can require a maximum amount of funds that it wants to receive
    // to invest. The strategy can also reject freeing funds if they are locked.
    function _updateDebt(address strategy, uint256 targetDebt) internal returns (uint256) {
        // How much we want the strategy to have.
        uint256 newDebt = targetDebt;
        // How much the strategy currently has.
        uint256 currentDebt = strategies[strategy].currentDebt;

        // If the vault is shutdown we can only pull funds.
        if (shutdown == true) {
            newDebt = 0;
        }

        if (newDebt == currentDebt) {
            revert DebtDidntChange();
        }

        if (currentDebt > newDebt) {
            // Reduce debt
            uint256 assetsToWithdraw = currentDebt - newDebt;

            // Respect minimum total idle in vault
            if (totalIdleAmount + assetsToWithdraw < minimumTotalIdle) {
                assetsToWithdraw = minimumTotalIdle - totalIdleAmount;
                // Cant withdraw more than the strategy has.
                if (assetsToWithdraw > currentDebt) {
                    assetsToWithdraw = currentDebt;
                }
            }

            // Check how much we are able to withdraw.
            // Use maxRedeem and convert since we use redeem.
            uint256 withdrawable = IStrategy(strategy).convertToAssets(IStrategy(strategy).maxRedeem(address(this)));

            if (withdrawable <= 0) {
                revert ZeroValue();
            }

            // If insufficient withdrawable, withdraw what we can.
            if (withdrawable < assetsToWithdraw) {
                assetsToWithdraw = withdrawable;
            }

            // If there are unrealised losses we don't let the vault reduce its debt until there is a new report
            uint256 unrealisedLossesShare = _assessShareOfUnrealisedLosses(strategy, assetsToWithdraw);
            if (unrealisedLossesShare != 0) {
                revert StrategyHasUnrealisedLosses();
            }

            // Always check the actual amount withdrawn.
            uint256 preBalance = ASSET.balanceOf(address(this));
            _withdrawFromStrategy(strategy, assetsToWithdraw);
            uint256 postBalance = ASSET.balanceOf(address(this));

            // making sure we are changing idle according to the real result no matter what. 
            // We pull funds with {redeem} so there can be losses or rounding differences.
            uint256 withdrawn = Math.min(postBalance - preBalance, currentDebt);

            // If we got too much make sure not to increase PPS.
            if (withdrawn > assetsToWithdraw) {
                assetsToWithdraw = withdrawn;
            }

            // Update storage.
            totalIdleAmount += withdrawn; // actual amount we got.
            // Amount we tried to withdraw in case of losses
            totalDebtAmount -= assetsToWithdraw;

            newDebt = currentDebt - assetsToWithdraw;
        } else {
            // We are increasing the strategies debt

            // Revert if target_debt cannot be achieved due to configured max_debt for given strategy
            if (newDebt > strategies[strategy].maxDebt) {
                revert DebtHigherThanMaxDebt();
            }

            // Vault is increasing debt with the strategy by sending more funds.
            uint256 currentMaxDeposit = IStrategy(strategy).maxDeposit(address(this));
            if (currentMaxDeposit <= 0) {
                revert ZeroValue();
            }

            // Deposit the difference between desired and current.
            uint256 assetsToDeposit = newDebt - currentDebt;
            if (assetsToDeposit > currentMaxDeposit) {
                // Deposit as much as possible.
                assetsToDeposit = currentMaxDeposit;
            }

            if (totalIdleAmount <= minimumTotalIdle) {
                revert InsufficientFunds();
            }
            uint256 availableIdle = totalIdleAmount - minimumTotalIdle;

            // If insufficient funds to deposit, transfer only what is free.
            if (assetsToDeposit > availableIdle) {
                assetsToDeposit = availableIdle;
            }

            // Can't Deposit 0.
            if (assetsToDeposit > 0) {
                // Approve the strategy to pull only what we are giving it.
                _erc20SafeApprove(address(ASSET), strategy, assetsToDeposit);

                // Always update based on actual amounts deposited.
                uint256 preBalance = ASSET.balanceOf(address(this));
                IStrategy(strategy).deposit(assetsToDeposit, address(this));
                uint256 postBalance = ASSET.balanceOf(address(this));

                // Make sure our approval is always back to 0.
                _erc20SafeApprove(address(ASSET), strategy, 0);

                // Making sure we are changing according to the real result no 
                // matter what. This will spend more gas but makes it more robust.
                assetsToDeposit = preBalance - postBalance;

                // Update storage.
                totalIdleAmount -= assetsToDeposit;
                totalDebtAmount += assetsToDeposit;

                newDebt = currentDebt + assetsToDeposit;
            }
        }

        // Commit memory to storage.
        strategies[strategy].currentDebt = newDebt;

        emit DebtUpdated(strategy, currentDebt, newDebt);
        return newDebt;
    }

    // ACCOUNTING MANAGEMENT
    // Processing a report means comparing the debt that the strategy has taken 
    // with the current amount of funds it is reporting. If the strategy owes 
    // less than it currently has, it means it has had a profit, else (assets < debt) 
    // it has had a loss.

    // Different strategies might choose different reporting strategies: pessimistic, 
    // only realised P&L, ... The best way to report depends on the strategy.

    // The profit will be distributed following a smooth curve over the vaults 
    // profit_max_unlock_time seconds. Losses will be taken immediately, first from the 
    // profit buffer (avoiding an impact in pps), then will reduce pps.

    // Any applicable fees are charged and distributed during the report as well
    // to the specified recipients.
    function _processReport(address strategy) internal returns (uint256, uint256) {
        // Make sure we have a valid strategy.
        if (strategies[strategy].activation == 0) {
            revert InactiveStrategy();
        }

        // Burn shares that have been unlocked since the last update
        _burnUnlockedShares();

        (uint256 gain, uint256 loss) = _assessProfitAndLoss(strategy);

        FeeAssessment memory fees = _assessFees(strategy, gain, loss);

        ShareManagement memory shares = _calculateShareManagement(loss, fees.totalFees, fees.protocolFees);

        (uint256 previouslyLockedShares, uint256 newlyLockedShares) = _handleShareBurnsAndIssues(shares, fees, gain, loss, strategy);

        _manageUnlockingOfShares(previouslyLockedShares, newlyLockedShares);

        // Record the report of profit timestamp.
        strategies[strategy].lastReport = block.timestamp;

        // We have to recalculate the fees paid for cases with an overall loss.
        emit StrategyReported(
            strategy,
            gain,
            loss,
            strategies[strategy].currentDebt,
            _convertToAssets(shares.protocolFeesShares, Rounding.ROUND_DOWN),
            _convertToAssets(shares.protocolFeesShares + shares.accountantFeesShares, Rounding.ROUND_DOWN),
            fees.totalRefunds
        );

        return (gain, loss);
    }

    // Assess the profit and loss of a strategy.
    function _assessProfitAndLoss(address strategy) internal view returns (uint256 gain, uint256 loss) {
        // Vault assesses profits using 4626 compliant interface.
        // NOTE: It is important that a strategies `convertToAssets` implementation
        // cannot be manipulated or else the vault could report incorrect gains/losses.
        uint256 strategyShares = IStrategy(strategy).balanceOf(address(this));
        // How much the vaults position is worth.
        uint256 currentTotalAssets = IStrategy(strategy).convertToAssets(strategyShares);
        // How much the vault had deposited to the strategy.
        uint256 currentDebt = strategies[strategy].currentDebt;

        uint256 _gain = 0;
        uint256 _loss = 0;

        // Compare reported assets vs. the current debt.
        if (currentTotalAssets > currentDebt) {
            // We have a gain.
            _gain = currentTotalAssets - currentDebt;
        } else {
            // We have a loss.
            _loss = currentDebt - currentTotalAssets;
        }

        return (_gain, _loss);
    }

    // Calculate and distribute any fees and refunds from the strategy's performance.
    function _assessFees(address strategy, uint256 gain, uint256 loss) internal returns (FeeAssessment memory) {
        FeeAssessment memory fees;

        // If accountant is not set, fees and refunds remain unchanged.
        if (accountant != address(0)) {
            (fees.totalFees, fees.totalRefunds) = IAccountant(accountant).report(strategy, gain, loss);

            // Protocol fees will be 0 if accountant fees are 0.
            if (fees.totalFees > 0) {
                uint16 protocolFeeBps;
                // Get the config for this vault.
                (protocolFeeBps, fees.protocolFeeRecipient) = IFactory(FACTORY).protocolFeeConfig();
                
                if (protocolFeeBps > 0) {
                    // Protocol fees are a percent of the fees the accountant is charging.
                    fees.protocolFees = fees.totalFees * uint256(protocolFeeBps) / MAX_BPS;
                }
            }
        }

        return fees;
    }

    // Calculate share management based on gains, losses, and fees.
    function _calculateShareManagement(uint256 loss, uint256 totalFees, uint256 protocolFees) internal view returns (ShareManagement memory) {
        // `shares_to_burn` is derived from amounts that would reduce the vaults PPS.
        // NOTE: this needs to be done before any pps changes
        ShareManagement memory shares;

        // Only need to burn shares if there is a loss or fees.
        if (loss + totalFees > 0) {
            // The amount of shares we will want to burn to offset losses and fees.
            shares.sharesToBurn += _convertToShares(loss + totalFees, Rounding.ROUND_UP);

            // Vault calculates the amount of shares to mint as fees before changing totalAssets / totalSupply.
            if (totalFees > 0) {
                // Accountant fees are total fees - protocol fees.
                shares.accountantFeesShares = _convertToShares(totalFees - protocolFees, Rounding.ROUND_DOWN);
                if (protocolFees > 0) {
                    shares.protocolFeesShares = _convertToShares(protocolFees, Rounding.ROUND_DOWN);
                }
            }
        }

        return shares;
    }

    // Handle the burning and issuing of shares based on the strategy's report.
    function _handleShareBurnsAndIssues(
        ShareManagement memory shares, 
        FeeAssessment memory fees, 
        uint256 gain, 
        uint256 loss, 
        address strategy
    ) internal returns (uint256 previouslyLockedShares, uint256 newlyLockedShares) {
        // Shares to lock is any amounts that would otherwise increase the vaults PPS.
        uint256 _newlyLockedShares;
        if (fees.totalRefunds > 0) {
            // Make sure we have enough approval and enough asset to pull.
            fees.totalRefunds = Math.min(fees.totalRefunds, Math.min(ASSET.balanceOf(accountant), ASSET.allowance(accountant, address(this))));
            // Transfer the refunded amount of asset to the vault.
            _erc20SafeTransferFrom(address(ASSET), accountant, address(this), fees.totalRefunds);
            // Update storage to increase total assets.
            totalIdleAmount += fees.totalRefunds;
        }

        // Record any reported gains.
        if (gain > 0) {
            // NOTE: this will increase total_assets
            strategies[strategy].currentDebt += gain;
            totalDebtAmount += gain;
        }

        // Mint anything we are locking to the vault.
        if (gain + fees.totalRefunds > 0 && profitMaxUnlockTime != 0) {
            _newlyLockedShares = _issueSharesForAmount(gain + fees.totalRefunds, address(this));
        }

        // Strategy is reporting a loss
        if (loss > 0) {
            strategies[strategy].currentDebt -= loss;
            totalDebtAmount -= loss;
        }

        // NOTE: should be precise (no new unlocked shares due to above's burn of shares)
        // newly_locked_shares have already been minted / transferred to the vault, so they need to be subtracted
        // no risk of underflow because they have just been minted.
        uint256 _previouslyLockedShares = _balanceOf[address(this)] - _newlyLockedShares;

        // Now that pps has updated, we can burn the shares we intended to burn as a result of losses/fees.
        // NOTE: If a value reduction (losses / fees) has occurred, prioritize burning locked profit to avoid
        // negative impact on price per share. Price per share is reduced only if losses exceed locked value.
        if (shares.sharesToBurn > 0) {
            // Cant burn more than the vault owns.
            shares.sharesToBurn = Math.min(shares.sharesToBurn, _previouslyLockedShares + _newlyLockedShares);
            _burnShares(shares.sharesToBurn, address(this));

            // We burn first the newly locked shares, then the previously locked shares.
            uint256 sharesNotToLock = Math.min(shares.sharesToBurn, _newlyLockedShares);
            // Reduce the amounts to lock by how much we burned
            _newlyLockedShares -= sharesNotToLock;
            _previouslyLockedShares -= (shares.sharesToBurn - sharesNotToLock);
        }

        // Issue shares for fees that were calculated above if applicable.
        if (shares.accountantFeesShares > 0) {
            _issueShares(shares.accountantFeesShares, accountant);
        }

        if (shares.protocolFeesShares > 0) {
            _issueShares(shares.protocolFeesShares, fees.protocolFeeRecipient);
        }

        return (_previouslyLockedShares, _newlyLockedShares);
    }

    // Manage the unlocking of shares over time based on the vault's configuration.
    function _manageUnlockingOfShares(uint256 previouslyLockedShares, uint256 newlyLockedShares) internal {
        // Update unlocking rate and time to fully unlocked.
        uint256 totalLockedShares = previouslyLockedShares + newlyLockedShares;
        if (totalLockedShares > 0) {
            uint256 previouslyLockedTime = 0;
            // Check if we need to account for shares still unlocking.
            if (fullProfitUnlockDate > block.timestamp) {
                // There will only be previously locked shares if time remains.
                // We calculate this here since it will not occur every time we lock shares.
                previouslyLockedTime = previouslyLockedShares * (fullProfitUnlockDate - block.timestamp);
            }

            // newProfitLockingPeriod is a weighted average between the remaining time of the previously locked shares and the profitMaxUnlockTime
            uint256 newProfitLockingPeriod = (previouslyLockedTime + newlyLockedShares * profitMaxUnlockTime) / totalLockedShares;
            // Calculate how many shares unlock per second.
            profitUnlockingRate = totalLockedShares * MAX_BPS_EXTENDED / newProfitLockingPeriod;
            // Calculate how long until the full amount of shares is unlocked.
            fullProfitUnlockDate = block.timestamp + newProfitLockingPeriod;
            // Update the last profitable report timestamp.
            lastProfitUpdate = block.timestamp;
        } else {
            // NOTE: only setting this to 0 will turn in the desired effect, no need 
            // to update last_profit_update or full_profit_unlock_date
            profitUnlockingRate = 0;
        }
    }

    // SETTERS
    // @notice Set the new accountant address.
    // @param new_accountant The new accountant address.
    function setAccountant(address newAccountant) external override onlyRole(ACCOUNTANT_MANAGER) {
        accountant = newAccountant;
        emit UpdateAccountant(newAccountant);
    }

    // @notice Set the new default queue array.
    // @dev Will check each strategy to make sure it is active.
    // @param new_default_queue The new default queue array.
    function setDefaultQueue(address[] calldata newDefaultQueue) external override onlyRole(QUEUE_MANAGER) {
        // Make sure every strategy in the new queue is active.
        for (uint i = 0; i < newDefaultQueue.length; i++) {
            address strategy = newDefaultQueue[i];
            if (strategies[strategy].activation == 0) {
                revert InactiveStrategy();
            }
        }
        // Save the new queue.
        defaultQueue = newDefaultQueue;
        emit UpdateDefaultQueue(newDefaultQueue);
    }

    // @notice Set a new value for `use_default_queue`.
    // @dev If set `True` the default queue will always be
    //  used no matter whats passed in.
    // @param use_default_queue new value.
    function setUseDefaultQueue(bool _useDefaultQueue) external override onlyRole(QUEUE_MANAGER) {
        useDefaultQueue = _useDefaultQueue;
        emit UpdateUseDefaultQueue(_useDefaultQueue);
    }

    // @notice Set the new deposit limit.
    // @dev Can not be changed if a deposit_limit_module
    //  is set or if shutdown.
    // @param deposit_limit The new deposit limit.
    function setDepositLimit(uint256 _depositLimit) external override onlyRole(DEPOSIT_LIMIT_MANAGER) {
        if (shutdown == true) {
            revert StrategyIsShutdown();
        }
        if (depositLimitModule != address(0)) {
            revert UsingModule();
        }
        depositLimit = _depositLimit;
        emit UpdateDepositLimit(_depositLimit);
    }

    // @notice Set a contract to handle the deposit limit.
    // @dev The default `deposit_limit` will need to be set to
    //  max uint256 since the module will override it.
    // @param deposit_limit_module Address of the module.
    function setDepositLimitModule(address _depositLimitModule) external override onlyRole(DEPOSIT_LIMIT_MANAGER) {
        if (shutdown == true) {
            revert StrategyIsShutdown();
        }
        if (depositLimit != type(uint256).max) {
            revert UsingDepositLimit();
        }
        depositLimitModule = _depositLimitModule;
        emit UpdateDepositLimitModule(_depositLimitModule);
    }

    // @notice Set a contract to handle the withdraw limit.
    // @dev This will override the default `max_withdraw`.
    // @param withdraw_limit_module Address of the module.
    function setWithdrawLimitModule(address _withdrawLimitModule) external override onlyRole(WITHDRAW_LIMIT_MANAGER) {
        withdrawLimitModule = _withdrawLimitModule;
        emit UpdateWithdrawLimitModule(_withdrawLimitModule);
    }

    // @notice Set the new minimum total idle.
    // @param minimum_total_idle The new minimum total idle.
    function setMinimumTotalIdle(uint256 _minimumTotalIdle) external override onlyRole(MINIMUM_IDLE_MANAGER) {
        minimumTotalIdle = _minimumTotalIdle;
        emit UpdateMinimumTotalIdle(_minimumTotalIdle);
    }

    // @notice Set the new profit max unlock time.
    // @dev The time is denominated in seconds and must be less than 1 year.
    //  We only need to update locking period if setting to 0,
    //  since the current period will use the old rate and on the next
    //  report it will be reset with the new unlocking time.
    
    //  Setting to 0 will cause any currently locked profit to instantly
    //  unlock and an immediate increase in the vaults Price Per Share.

    // @param new_profit_max_unlock_time The new profit max unlock time.
    function setProfitMaxUnlockTime(uint256 _newProfitMaxUnlockTime) external override onlyRole(PROFIT_UNLOCK_MANAGER) {
        // Must be less than one year for report cycles
        if (_newProfitMaxUnlockTime > ONE_YEAR) {
            revert ProfitUnlockTimeTooLong();
        }

        // If setting to 0 we need to reset any locked values.
        if (_newProfitMaxUnlockTime == 0) {
            // Burn any shares the vault still has.
            _burnShares(_balanceOf[address(this)], address(this));
            // Reset unlocking variables to 0.
            profitUnlockingRate = 0;
            fullProfitUnlockDate = 0;
        }
        profitMaxUnlockTime = _newProfitMaxUnlockTime;
        emit UpdateProfitMaxUnlockTime(_newProfitMaxUnlockTime);
    }

    // ROLE MANAGEMENT

    // @notice Add a new role to an address.
    // @dev This will add a new role to the account
    //  without effecting any of the previously held roles.
    // @param account The account to add a role to.
    // @param role The new role to add to account.
    function addRole(address account, bytes32 role) public override onlyRole(ROLE_MANAGER) {
        _grantRole(role, account);
        emit RoleSet(account, role);
    }

    // @notice Remove a single role from an account.
    // @dev This will leave all other roles for the 
    //  account unchanged.
    // @param account The account to remove a Role from.
    // @param role The Role to remove.
    function removeRole(address account, bytes32 role) external override onlyRole(ROLE_MANAGER) {
        _revokeRole(role, account);
        emit RoleSet(account, role);
    }

    // @notice Set a role to be open.
    // @param role The role to set.
    function setOpenRole(bytes32 role) external override onlyRole(ROLE_MANAGER) {
        openRoles[role] = true;
        emit RoleStatusChanged(role, RoleStatusChange.OPENED);
    }

    // @notice Close a opened role.
    // @param role The role to close.
    function closeOpenRole(bytes32 role) external override onlyRole(ROLE_MANAGER) {
        openRoles[role] = false;
        emit RoleStatusChanged(role, RoleStatusChange.CLOSED);
    }

    // @notice Step 1 of 2 in order to transfer the 
    //    role manager to a new address. This will set
    //    the future_role_manager. Which will then need
    //    to be accepted by the new manager.
    // @param role_manager The new role manager address.
    function transferRoleManager(address newRoleManager) external override onlyRole(ROLE_MANAGER) {
        futureRoleManager = newRoleManager;
    }

    // @notice Accept the role manager transfer.
    function acceptRoleManager() external override {
        if (msg.sender != futureRoleManager) {
            revert CallerIsNotTheFutureRoleManager();
        }
        roleManager = msg.sender;
        futureRoleManager = address(0);
        emit UpdateRoleManager(msg.sender);
    }

    // VAULT STATUS VIEWS

    // @notice Get the amount of shares that have been unlocked.
    // @return The amount of shares that are have been unlocked.
    function unlockedShares() external view override returns (uint256) {
        return _unlockedShares();
    }

    // @notice Get the price per share (pps) of the vault.
    // @dev This value offers limited precision. Integrations that require 
    //    exact precision should use convertToAssets or convertToShares instead.
    // @return The price per share.
    function pricePerShare() external view override returns (uint256) {
        return _convertToAssets(10**DECIMALS, Rounding.ROUND_DOWN);
    }

    // REPORTING MANAGEMENT
    
    // @notice Process the report of a strategy.
    // @param strategy The strategy to process the report for.
    // @return The gain and loss of the strategy.
    function processReport(address strategy) external override onlyRole(REPORTING_MANAGER) nonReentrant returns (uint256, uint256) {
        return _processReport(strategy);
    }

    // @notice Used for governance to buy bad debt from the vault.
    // @dev This should only ever be used in an emergency in place
    //  of force revoking a strategy in order to not report a loss.
    //  It allows the DEBT_PURCHASER role to buy the strategies debt
    //  for an equal amount of `asset`. 

    // @param strategy The strategy to buy the debt for
    // @param amount The amount of debt to buy from the vault.
    function buyDebt(address strategy, uint256 amount) external override onlyRole(DEBT_PURCHASER) nonReentrant {
        if (strategies[strategy].activation == 0) {
            revert InactiveStrategy();
        }

        // Cache the current debt.
        uint256 currentDebt = strategies[strategy].currentDebt;

        if (currentDebt <= 0 || amount <= 0) {
            revert ZeroValue();
        }

        if (amount > currentDebt) {
            amount = currentDebt;
        }

        // We get the proportion of the debt that is being bought and
        // transfer the equivalent shares. We assume this is being used
        // due to strategy issues so won't rely on its conversion rates.
        uint256 shares = IERC20(strategy).balanceOf(address(this)) * amount / currentDebt;

        if (shares <= 0) {
            revert ZeroValue();
        }

        _erc20SafeTransferFrom(address(ASSET), msg.sender, address(this), amount);

        // Lower strategy debt
        strategies[strategy].currentDebt -= amount;
        // lower total debt
        totalDebtAmount -= amount;
        // Increase total idle
        totalIdleAmount += amount;

        // Log debt change
        emit DebtUpdated(strategy, currentDebt, currentDebt - amount);

        // Transfer the strategies shares out
        _erc20SafeTransfer(strategy, msg.sender, shares);

        // Log the debt purchase
        emit DebtPurchased(strategy, amount);
    }

    // STRATEGY MANAGEMENT

    // @notice Add a new strategy.
    // @param new_strategy The new strategy to add.
    function addStrategy(address newStrategy) external override onlyRole(ADD_STRATEGY_MANAGER) {
        _addStrategy(newStrategy);
    }

    // @notice Revoke a strategy.
    // @param strategy The strategy to revoke.
    function revokeStrategy(address strategy) external override onlyRole(REVOKE_STRATEGY_MANAGER) {
        _revokeStrategy(strategy, false);
    }

    // @notice Force revoke a strategy.
    // @dev The vault will remove the strategy and write off any debt left 
    //    in it as a loss. This function is a dangerous function as it can force a 
    //    strategy to take a loss. All possible assets should be removed from the 
    //    strategy first via update_debt. If a strategy is removed erroneously it 
    //    can be re-added and the loss will be credited as profit. Fees will apply.
    // @param strategy The strategy to force revoke.
    function forceRevokeStrategy(address strategy) external override onlyRole(FORCE_REVOKE_MANAGER) {
        _revokeStrategy(strategy, true);
    }

    // DEBT MANAGEMENT

    // @notice Update the max debt for a strategy.
    // @param strategy The strategy to update the max debt for.
    // @param new_max_debt The new max debt for the strategy.
    function updateMaxDebtForStrategy(address strategy, uint256 newMaxDebt) external override onlyRole(MAX_DEBT_MANAGER) {
        if (strategies[strategy].activation == 0) {
            revert InactiveStrategy();
        }
        strategies[strategy].maxDebt = newMaxDebt;
        emit UpdatedMaxDebtForStrategy(msg.sender, strategy, newMaxDebt);
    }

    // @notice Update the debt for a strategy.
    // @param strategy The strategy to update the debt for.
    // @param target_debt The target debt for the strategy.
    // @return The amount of debt added or removed.
    function updateDebt(address strategy, uint256 targetDebt) external override onlyRole(DEBT_MANAGER) nonReentrant returns (uint256) {
        return _updateDebt(strategy, targetDebt);
    }

    // EMERGENCY MANAGEMENT

    // @notice Shutdown the vault.
    function shutdownVault() external override onlyRole(EMERGENCY_MANAGER) {
        if (shutdown == true) {
            revert InactiveStrategy();
        }

        // Shutdown the vault.
        shutdown = true;

        // Set deposit limit to 0.
        if (depositLimitModule != address(0)) {
            depositLimitModule = address(0);
            emit UpdateDepositLimitModule(address(0));
        }

        depositLimit = 0;
        emit UpdateDepositLimit(0);

        addRole(msg.sender, DEBT_MANAGER);
        emit Shutdown();
    }

    // ## SHARE MANAGEMENT ##
    // ## ERC20 + ERC4626 ##

    // @notice Deposit assets into the vault.
    // @param assets The amount of assets to deposit.
    // @param receiver The address to receive the shares.
    // @return The amount of shares minted.
    function deposit(uint256 assets, address receiver) external override nonReentrant returns (uint256) {
        return _deposit(msg.sender, receiver, assets);
    }

    // @notice Mint shares for the receiver.
    // @param shares The amount of shares to mint.
    // @param receiver The address to receive the shares.
    // @return The amount of assets deposited.
    function mint(uint256 shares, address receiver) external override nonReentrant returns (uint256) {
        return _mint(msg.sender, receiver, shares);
    }

    // @notice Withdraw an amount of asset to `receiver` burning `owner`s shares.
    // @dev The default behavior is to not allow any loss.
    // @param assets The amount of asset to withdraw.
    // @param receiver The address to receive the assets.
    // @param owner The address who's shares are being burnt.
    // @param max_loss Optional amount of acceptable loss in Basis Points.
    // @param strategies Optional array of strategies to withdraw from.
    // @return The amount of shares actually burnt.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] memory _strategies
    ) external override nonReentrant returns (uint256) {
        uint256 shares = _convertToShares(assets, Rounding.ROUND_UP);
        _redeem(msg.sender, receiver, owner, assets, shares, maxLoss, _strategies);
        return shares;
    }

    // @notice Redeems an amount of shares of `owners` shares sending funds to `receiver`.
    // @dev The default behavior is to allow losses to be realized.
    // @param shares The amount of shares to burn.
    // @param receiver The address to receive the assets.
    // @param owner The address who's shares are being burnt.
    // @param max_loss Optional amount of acceptable loss in Basis Points.
    // @param strategies Optional array of strategies to withdraw from.
    // @return The amount of assets actually withdrawn.
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] memory _strategies
    ) external override nonReentrant returns (uint256) {
        uint256 assets = _convertToAssets(shares, Rounding.ROUND_DOWN);
        // Always return the actual amount of assets withdrawn.
        return _redeem(msg.sender, receiver, owner, assets, shares, maxLoss, _strategies);
    }

    // @notice Approve an address to spend the vault's shares.
    // @param spender The address to approve.
    // @param amount The amount of shares to approve.
    // @return True if the approval was successful.
    function approve(address spender, uint256 amount) external override returns (bool) {
        return _approve(msg.sender, spender, amount);
    }

    // @notice Transfer shares to a receiver.
    // @param receiver The address to transfer shares to.
    // @param amount The amount of shares to transfer.
    // @return True if the transfer was successful.
    function transfer(address receiver, uint256 amount) external override returns (bool) {
        if (receiver == address(this) || receiver == address(0)) {
            revert ZeroAddress();
        }
        _transfer(msg.sender, receiver, amount);
        return true;
    }

    // @notice Transfer shares from a sender to a receiver.
    // @param sender The address to transfer shares from.
    // @param receiver The address to transfer shares to.
    // @param amount The amount of shares to transfer.
    // @return True if the transfer was successful.
    function transferFrom(address sender, address receiver, uint256 amount) external override returns (bool) {
        if (receiver == address(this) || receiver == address(0)) {
            revert ZeroAddress();
        }
        return _transferFrom(sender, receiver, amount);
    }

    // ## ERC20+4626 compatibility

    // @notice Increase the allowance for a spender.
    // @param spender The address to increase the allowance for.
    // @param amount The amount to increase the allowance by.
    // @return True if the increase was successful.
    function increaseAllowance(address spender, uint256 amount) external override returns (bool) {
        return _increaseAllowance(msg.sender, spender, amount);
    }

    // @notice Decrease the allowance for a spender.
    // @param spender The address to decrease the allowance for.
    // @param amount The amount to decrease the allowance by.
    // @return True if the decrease was successful.
    function decreaseAllowance(address spender, uint256 amount) external override returns (bool) {
        return _decreaseAllowance(msg.sender, spender, amount);
    }

    // @notice Approve an address to spend the vault's shares.
    // @param owner The address to approve.
    // @param spender The address to approve.
    // @param amount The amount of shares to approve.
    // @param deadline The deadline for the permit.
    // @param v The v component of the signature.
    // @param r The r component of the signature.
    // @param s The s component of the signature.
    // @return True if the approval was successful.
    function permit(
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override returns (bool) {
        return _permit(owner, spender, amount, deadline, v, r, s);
    }

    // @notice Get the balance of a user.
    // @param addr The address to get the balance of.
    // @return The balance of the user.
    function balanceOf(address addr) external view override returns (uint256) {
        if(addr == address(this)) {
            return _balanceOf[addr] - _unlockedShares();
        }
        return _balanceOf[addr];
    }

    // @notice Get the total supply of shares.
    // @return The total supply of shares.
    function totalSupply() external view override(IERC20, IVault) returns (uint256) {
        return _totalSupply();
    }

    // @notice Get the address of the asset.
    // @return The address of the asset.
    function asset() external view override returns (address) {
        return address(ASSET);
    }

    // @notice Get the number of decimals of the asset/share.
    // @return The number of decimals of the asset/share.
    function decimals() external view override returns (uint8) {
        return uint8(DECIMALS);
    }

    // @notice Get the total assets held by the vault.
    // @return The total assets held by the vault.
    function totalAssets() external view override returns (uint256) {
        return _totalAssets();
    }

    // @notice Convert an amount of assets to shares.
    // @param assets The amount of assets to convert.
    // @return The amount of shares.
    function convertToShares(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, Rounding.ROUND_DOWN);
    }

    // @notice Preview the amount of shares that would be minted for a deposit.
    // @param assets The amount of assets to deposit.
    // @return The amount of shares that would be minted.
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, Rounding.ROUND_DOWN);
    }

    // @notice Preview the amount of assets that would be deposited for a mint.
    // @param shares The amount of shares to mint.
    // @return The amount of assets that would be deposited.
    function previewMint(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, Rounding.ROUND_UP);
    }

    // @notice Convert an amount of shares to assets.
    // @param shares The amount of shares to convert.
    // @return The amount of assets.
    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, Rounding.ROUND_DOWN);
    }

    // @notice Get the maximum amount of assets that can be deposited.
    // @param receiver The address that will receive the shares.
    // @return The maximum amount of assets that can be deposited.
    function maxDeposit(address receiver) external view override returns (uint256) {
        return _maxDeposit(receiver);
    }

    // @notice Get the maximum amount of shares that can be minted.
    // @param receiver The address that will receive the shares.
    // @return The maximum amount of shares that can be minted.
    function maxMint(address receiver) external view override returns (uint256) {
        uint256 maxDepositAmount = _maxDeposit(receiver);
        return _convertToShares(maxDepositAmount, Rounding.ROUND_DOWN);
    }

    // @notice Get the maximum amount of assets that can be withdrawn.
    // @dev Complies to normal 4626 interface and takes custom params.
    // @param owner The address that owns the shares.
    // @param max_loss Custom max_loss if any.
    // @param strategies Custom strategies queue if any.
    // @return The maximum amount of assets that can be withdrawn.
    function maxWithdraw(address owner, uint256 maxLoss, address[] memory _strategies) external override returns (uint256) {
        return _maxWithdraw(owner, maxLoss, _strategies);
    }

    // @notice Get the maximum amount of shares that can be redeemed.
    // @dev Complies to normal 4626 interface and takes custom params.
    // @param owner The address that owns the shares.
    // @param max_loss Custom max_loss if any.
    // @param strategies Custom strategies queue if any.
    // @return The maximum amount of shares that can be redeemed.
    function maxRedeem(address owner, uint256 maxLoss, address[] memory _strategies) external override returns (uint256) {
        uint256 maxWithdrawAmount = _maxWithdraw(owner, maxLoss, _strategies);
        uint256 sharesEquivalent = _convertToShares(maxWithdrawAmount, Rounding.ROUND_UP);
        return Math.min(sharesEquivalent, _balanceOf[owner]);
    }

    // @notice Preview the amount of shares that would be redeemed for a withdraw.
    // @param assets The amount of assets to withdraw.
    // @return The amount of shares that would be redeemed.
    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, Rounding.ROUND_UP);
    }

    // @notice Preview the amount of assets that would be withdrawn for a redeem.
    // @param shares The amount of shares to redeem.
    // @return The amount of assets that would be withdrawn.
    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, Rounding.ROUND_DOWN);
    }

    // @notice Assess the share of unrealised losses that a strategy has.
    // @param strategy The address of the strategy.
    // @param assets_needed The amount of assets needed to be withdrawn.
    // @return The share of unrealised losses that the strategy has.
    function assessShareOfUnrealisedLosses(address strategy, uint256 assetsNeeded) external view override returns (uint256) {
        // Assuming strategies mapping and _assess_share_of_unrealised_losses are defined
        if (strategies[strategy].currentDebt < assetsNeeded) {
            revert StrategyDebtIsLessThanAssetsNeeded();
        }
        return _assessShareOfUnrealisedLosses(strategy, assetsNeeded);
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowance[owner][spender];
    }

    // # eip-1344

    // EIP-712 domain separator
    function domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPE_HASH,
            keccak256("Yearn Vault"),
            keccak256(bytes(API_VERSION)),
            block.chainid,
            address(this)
        ));
    }
}
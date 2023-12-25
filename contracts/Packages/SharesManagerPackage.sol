// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../CommonErrors.sol";
import "../VaultStorage.sol";
import "../Interfaces/IVaultEvents.sol";
import "./Interfaces/ISharesManagerPackage.sol";
import "../StrategyManager.sol";
import "../Setters.sol";
import "../Interfaces/IStrategyManager.sol";
import "../Interfaces/IStrategy.sol";
import "../Interfaces/IDepositLimitModule.sol";
import "../Interfaces/IWithdrawLimitModule.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
@title STRATEGY MANAGEMENT
*/

contract SharesManagerPackage is VaultStorage, IVaultEvents, ReentrancyGuard, ISharesManagerPackage, AccessControl {
    // solhint-disable not-rely-on-time
    // solhint-disable var-name-mixedcase
    // solhint-disable function-max-lines
    // solhint-disable code-complexity
    // solhint-disable max-line-length
    // solhint-disable ordering

    using Math for uint256;

    // IMMUTABLE
    // Address of the underlying token used by the vault
    IERC20 public ASSET;
    uint8 public DECIMALS;

    // ERC20 - name of the vault's token
    string public override name;
    // ERC20 - symbol of the vault's token
    string public override symbol;

    function initialize(
        address payable _strategyManager,
        address payable _setters,
        address _asset,
        uint8 _decimals,
        string memory _name,
        string memory _symbol
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (initialized == true) {
            revert AlreadyInitialized();
        }
        strategyManager = _strategyManager;
        setters = _setters;

        DECIMALS = _decimals;
        if (DECIMALS >= 256) {
            revert InvalidAssetDecimals();
        }
        ASSET = IERC20(_asset);
        name = _name;
        symbol = _symbol;

        initialized = true;
    }

    // SHARE MANAGEMENT
    // ERC20

    // @notice Get the balance of a user.
    // @param addr The address to get the balance of.
    // @return The balance of the user.
    function balanceOf(address addr) external view override returns (uint256) {
        if (addr == address(this)) {
            return _balanceOf[addr] - _unlockedShares();
        }
        return _balanceOf[addr];
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowance[owner][spender];
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        // Unlimited approval does nothing (saves an SSTORE)
        uint256 currentAllowance = _allowance[owner][spender];
        if (currentAllowance < amount) {
            revert ERC20InsufficientAllowance(currentAllowance);
        }
        _approve(owner, spender, currentAllowance - amount);
    }

    function spendAllowance(address owner, address spender, uint256 amount) external override {
        _spendAllowance(owner, spender, amount);
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

    function transfer(address sender, address receiver, uint256 amount) external override {
        _transfer(sender, receiver, amount);
    }

    function transferFrom(address sender, address receiver, uint256 amount) external override returns (bool) {
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

    function approve(address owner, address spender, uint256 amount) external override returns (bool) {
        return _approve(owner, spender, amount);
    }

    function _increaseAllowance(address owner, address spender, uint256 amount) internal returns (bool) {
        uint256 newAllowance = _allowance[owner][spender] + amount;
        _approve(owner, spender, newAllowance);
        return true;
    }

    function increaseAllowance(address owner, address spender, uint256 amount) external override returns (bool) {
        return _increaseAllowance(owner, spender, amount);
    }

    function decreaseAllowance(address owner, address spender, uint256 amount) external override returns (bool) {
        uint256 newAllowance = _allowance[owner][spender] - amount;
        _approve(owner, spender, newAllowance);
        return true;
    }

    function permit(
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override returns (bool) {
        if (owner == address(0)) {
            revert ZeroAddress();
        }
        if (deadline < block.timestamp) {
            revert ERC20PermitExpired();
        }
        uint256 nonce = nonces[owner];

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPE_HASH, owner, spender, amount, nonce, deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        address recoveredAddress = ecrecover(digest, v, r, s);
        if (recoveredAddress == address(0) || recoveredAddress != owner) {
            revert ERC20PermitInvalidSignature(recoveredAddress);
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
            revert InsufficientShares(_balanceOf[owner]);
        }
        _balanceOf[owner] -= shares;
        totalSupplyAmount -= shares;
        emit Transfer(owner, address(0), shares);
    }

    function burnShares(uint256 shares, address owner) external override {
        _burnShares(shares, owner);
    }

    // Returns the amount of shares that have been unlocked.
    // To avoid sudden pricePerShare spikes, profits must be processed
    // through an unlocking period. The mechanism involves shares to be
    // minted to the vault which are unlocked gradually over time. Shares
    // that have been locked are gradually unlocked over profitMaxUnlockTime.
    function _unlockedShares() internal view returns (uint256) {
        uint256 _fullProfitUnlockDate = Setters(setters).fullProfitUnlockDate();
        uint256 currUnlockedShares = 0;
        if (_fullProfitUnlockDate > block.timestamp) {
            // If we have not fully unlocked, we need to calculate how much has been.
            currUnlockedShares = (Setters(setters).profitUnlockingRate() * (block.timestamp - lastProfitUpdate)) / MAX_BPS_EXTENDED;
        } else if (_fullProfitUnlockDate != 0) {
            // All shares have been unlocked
            currUnlockedShares = _balanceOf[address(this)];
        }
        return currUnlockedShares;
    }

    function unlockedShares() external view override returns (uint256) {
        return _unlockedShares();
    }

    // Need to account for the shares issued to the vault that have unlocked.
    function _totalSupply() internal view returns (uint256) {
        return totalSupplyAmount - _unlockedShares();
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply();
    }

    // Burns shares that have been unlocked since last update.
    // In case the full unlocking period has passed, it stops the unlocking.
    function burnUnlockedShares() external override {
        // Get the amount of shares that have unlocked
        uint256 currUnlockedShares = _unlockedShares();
        // IF 0 there's nothing to do.
        if (currUnlockedShares == 0) return;

        // Only do an SSTORE if necessary
        if (Setters(setters).fullProfitUnlockDate() > block.timestamp) {
            lastProfitUpdate = block.timestamp;
        }

        // Burn the shares unlocked.
        _burnShares(currUnlockedShares, address(this));
    }

    // Total amount of assets that are in the vault and in the strategies.
    function _totalAssets() internal view returns (uint256) {
        return totalIdleAmount + totalDebtAmount;
    }

    function totalAssets() external view override returns (uint256) {
        return _totalAssets();
    }

    // assets = shares * (totalAssets / totalSupply) --- (== pricePerShare * shares)
    function _convertToAssets(uint256 shares, Rounding rounding) internal view returns (uint256) {
        if (shares == type(uint256).max || shares == 0) {
            return shares;
        }

        uint256 currentTotalSupply = _totalSupply();
        // if totalSupply is 0, pricePerShare is 1
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

    function convertToAssets(uint256 shares, Rounding rounding) external view override returns (uint256) {
        return _convertToAssets(shares, rounding);
    }

    // shares = amount * (totalSupply / totalAssets) --- (== amount / pricePerShare)
    function _convertToShares(uint256 assets, Rounding rounding) internal view returns (uint256) {
        if (assets == type(uint256).max || assets == 0) {
            return assets;
        }

        uint256 currentTotalSupply = _totalSupply();
        uint256 currentTotalAssets = _totalAssets();

        if (currentTotalAssets == 0) {
            // if totalAssets and totalSupply is 0, pricePerShare is 1
            if (currentTotalSupply == 0) {
                return assets;
            } else {
                // Else if totalSupply > 0 pricePerShare is 0
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

    function convertToShares(uint256 assets, Rounding rounding) external view override returns (uint256) {
        return _convertToShares(assets, rounding);
    }

    // Used only to approve tokens that are not the type managed by this Vault.
    // Used to handle non-compliant tokens like USDT
    function erc20SafeApprove(address token, address spender, uint256 amount) external override {
        if (token == address(0) || spender == address(0)) {
            revert ZeroAddress();
        }
        if (!IERC20(token).approve(spender, amount)) {
            revert ERC20ApprovalFailed();
        }
    }

    // Used only to transfer tokens that are not the type managed by this Vault.
    // Used to handle non-compliant tokens like USDT
    function _erc20SafeTransferFrom(address token, address sender, address receiver, uint256 amount) internal {
        if (token == address(0) || sender == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        if (!IERC20(token).transferFrom(sender, receiver, amount)) {
            revert ERC20TransferFailed();
        }
    }

    function erc20SafeTransferFrom(address token, address sender, address receiver, uint256 amount) external override {
        _erc20SafeTransferFrom(token, sender, receiver, amount);
    }

    // Used only to send tokens that are not the type managed by this Vault.
    // Used to handle non-compliant tokens like USDT
    function _erc20SafeTransfer(address token, address receiver, uint256 amount) internal {
        if (token == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        if (!IERC20(token).transfer(receiver, amount)) {
            revert ERC20TransferFailed();
        }
    }

    function erc20SafeTransfer(address token, address receiver, uint256 amount) external override {
        _erc20SafeTransfer(token, receiver, amount);
    }

    function _issueShares(uint256 shares, address recipient) internal {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        _balanceOf[recipient] += shares;
        totalSupplyAmount += shares;
        emit Transfer(address(0), recipient, shares);
    }

    function issueShares(uint256 shares, address recipient) external override {
        _issueShares(shares, recipient);
    }

    // Issues shares that are worth 'amount' in the underlying token (asset).
    // WARNING: this takes into account that any new assets have been summed
    // to totalAssets (otherwise pps will go down).
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
            newShares = (amount * currentTotalSupply) / (currentTotalAssets - amount);
        } else {
            // If totalSupply > 0 but amount = totalAssets we want to revert because
            // after first deposit, getting here would mean that the rest of the shares
            // would be diluted to a pricePerShare of 0. Issuing shares would then mean
            // either the new depositor or the previous depositors will loose money.
            revert AmountTooHigh();
        }

        // We don't make the function revert
        if (newShares == 0) {
            return 0;
        }

        _issueShares(newShares, recipient);
        return newShares;
    }

    function issueSharesForAmount(uint256 amount, address recipient) external override returns (uint256) {
        return _issueSharesForAmount(amount, recipient);
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

    function maxDeposit(address receiver) external view override returns (uint256) {
        return _maxDeposit(receiver);
    }

    // @notice Preview the amount of shares that would be minted for a deposit.
    // @param assets The amount of assets to deposit.
    // @return The amount of shares that would be minted.
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, Rounding.ROUND_DOWN);
    }

    // @dev Returns the max amount of `asset` an `owner` can withdraw.
    // This will do a full simulation of the withdraw in order to determine
    // how much is currently liquid and if the `maxLoss` would allow for the
    // tx to not revert.
    // This will track any expected loss to check if the tx will revert, but
    // not account for it in the amount returned since it is unrealised and
    // therefore will not be accounted for in the conversion rates.
    // i.e. If we have 100 debt and 10 of unrealised loss, the max we can get
    // out is 90, but a user of the vault will need to call withdraw with 100
    // in order to get the full 90 out.
    function _maxWithdraw(address owner, uint256 _maxLoss, address[] memory _strategies) internal returns (uint256) {
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
                    revert InactiveStrategy(strategy);
                }

                // Get the maximum amount the vault would withdraw from the strategy.
                uint256 toWithdraw = Math.min(
                    maxAssets - have, // What we still need for the full withdraw
                    strategies[strategy].currentDebt // The current debt the strategy has.
                );

                // Get any unrealised loss for the strategy.
                uint256 unrealisedLoss = _assessShareOfUnrealisedLosses(strategy, toWithdraw);

                // See if any limit is enforced by the strategy.
                uint256 strategyLimit = IStrategy(strategy).convertToAssets(IStrategy(strategy).maxRedeem(address(this)));

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

                // If there would be a loss with a non-maximum `maxLoss` value.
                if (unrealisedLoss > 0 && _maxLoss < MAX_BPS) {
                    // Check if the loss is greater than the allowed range.
                    if (loss + unrealisedLoss > ((have + toWithdraw) * _maxLoss) / MAX_BPS) {
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

    function maxWithdraw(address owner, uint256 _maxLoss, address[] memory _strategies) external override returns (uint256) {
        return _maxWithdraw(owner, _maxLoss, _strategies);
    }

    // @notice Preview the amount of shares that would be redeemed for a withdraw.
    // @param assets The amount of assets to withdraw.
    // @return The amount of shares that would be redeemed.
    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, Rounding.ROUND_UP);
    }

    // @notice Withdraw an amount of asset to `receiver` burning `owner`s shares.
    // @dev The default behavior is to not allow any loss.
    // @param assets The amount of asset to withdraw.
    // @param receiver The address to receive the assets.
    // @param owner The address who's shares are being burnt.
    // @param maxLoss Optional amount of acceptable loss in Basis Points.
    // @param strategies Optional array of strategies to withdraw from.
    // @return The amount of shares actually burnt.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] memory _strategies
    ) external override returns (uint256) {
        uint256 shares = _convertToShares(assets, Rounding.ROUND_UP);
        _redeem(tx.origin, receiver, owner, assets, shares, maxLoss, _strategies);
        return shares;
    }

    // @notice Get the maximum amount of shares that can be redeemed.
    // @dev Complies to normal 4626 interface and takes custom params.
    // @param owner The address that owns the shares.
    // @param maxLoss Custom maxLoss if any.
    // @param strategies Custom strategies queue if any.
    // @return The maximum amount of shares that can be redeemed.
    function maxRedeem(address owner, uint256 maxLoss, address[] memory _strategies) external override returns (uint256) {
        uint256 maxWithdrawAmount = _maxWithdraw(owner, maxLoss, _strategies);
        uint256 sharesEquivalent = _convertToShares(maxWithdrawAmount, Rounding.ROUND_UP);
        return Math.min(sharesEquivalent, _balanceOf[owner]);
    }

    // @notice Preview the amount of assets that would be withdrawn for a redeem.
    // @param shares The amount of shares to redeem.
    // @return The amount of assets that would be withdrawn.
    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, Rounding.ROUND_DOWN);
    }

    // Used for `deposit` calls to transfer the amount of `asset` to the vault,
    // issue the corresponding shares to the `recipient` and update all needed
    // vault accounting.
    function _deposit(address sender, address recipient, uint256 assets) internal returns (uint256) {
        if (shutdown == true) {
            revert StrategyIsShutdown();
        }
        if (assets > _maxDeposit(recipient)) {
            revert ExceedDepositLimit(_maxDeposit(recipient));
        }
        if (assets <= 0) {
            revert ZeroValue();
        }

        // Transfer the tokens to the vault first.
        ASSET.transferFrom(tx.origin, address(this), assets);
        // Record the change in total assets.
        totalIdleAmount += assets;

        // Issue the corresponding shares for assets.
        uint256 shares = _issueSharesForAmount(assets, recipient);
        if (shares <= 0) {
            revert ZeroValue();
        }

        emit Deposit(sender, recipient, assets, shares);
        return shares;
    }

    function deposit(address sender, address recipient, uint256 assets) external override returns (uint256) {
        return _deposit(sender, recipient, assets);
    }

    // @notice Get the maximum amount of shares that can be minted.
    // @param receiver The address that will receive the shares.
    // @return The maximum amount of shares that can be minted.
    function maxMint(address receiver) external view override returns (uint256) {
        uint256 maxDepositAmount = _maxDeposit(receiver);
        return _convertToShares(maxDepositAmount, Rounding.ROUND_DOWN);
    }

    // @notice Preview the amount of assets that would be deposited for a mint.
    // @param shares The amount of shares to mint.
    // @return The amount of assets that would be deposited.
    function previewMint(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, Rounding.ROUND_UP);
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

        if (assets <= 0) {
            revert ZeroValue();
        }
        if (assets > _maxDeposit(recipient)) {
            revert ExceedDepositLimit(_maxDeposit(recipient));
        }

        // Transfer the tokens to the vault first.
        ASSET.transferFrom(sender, address(this), assets);
        // Record the change in total assets.
        totalIdleAmount += assets;

        // Issue the corresponding shares for assets.
        _issueShares(shares, recipient); // Assuming _issueShares is defined elsewhere

        emit Deposit(sender, recipient, assets, shares);
        return assets;
    }

    function mint(address sender, address recipient, uint256 shares) external override returns (uint256) {
        return _mint(sender, recipient, shares);
    }

    // Returns the share of losses that a user would take if withdrawing from this strategy
    // e.g. if the strategy has unrealised losses for 10% of its current debt and the user
    // wants to withdraw 1000 tokens, the losses that he will take are 100 token
    function _assessShareOfUnrealisedLosses(address strategy, uint256 assetsNeeded) internal view returns (uint256) {
        // Minimum of how much debt the debt should be worth.
        (, , uint256 strategyCurrentDebt, ) = StrategyManager(strategyManager).strategies(strategy);
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

    function assessShareOfUnrealisedLosses(address strategy, uint256 assetsNeeded) external view override returns (uint256) {
        // Assuming strategies mapping and _assess_share_of_unrealised_losses are defined
        (, , uint256 strategyCurrentDebt, ) = StrategyManager(strategyManager).strategies(strategy);
        if (strategyCurrentDebt < assetsNeeded) {
            revert StrategyDebtIsLessThanAssetsNeeded(strategyCurrentDebt);
        }
        return _assessShareOfUnrealisedLosses(strategy, assetsNeeded);
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

    function withdrawFromStrategy(address strategy, uint256 assetsToWithdraw) external override {
        _withdrawFromStrategy(strategy, assetsToWithdraw);
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
    function _validateRedeem(address receiver, address owner, uint256 sharesToBurn, uint256 maxLoss) internal view {
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
            revert InsufficientShares(_balanceOf[owner]);
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
            address[] memory currentStrategies;
            uint256 defaultQueueLength;
            if (_strategies.length != 0 && !StrategyManager(strategyManager).useDefaultQueue()) {
                // If a custom queue was passed, and we don't force the default queue.
                // Use the custom queue.
                defaultQueueLength = _strategies.length;
                currentStrategies = _strategies;
            } else {
                currentStrategies = IStrategyManager(strategyManager).getDefaultQueue();
            }

            // Withdraw from strategies only what idle doesn't cover.
            // `assetsNeeded` is the total amount we need to fill the request.
            state.assetsNeeded = state.requestedAssets - state.currTotalIdle;

            // Assuming _strategies is an array of addresses representing the strategies
            for (uint256 i = 0; i < currentStrategies.length; i++) {
                address strategy = currentStrategies[i];
                // Make sure we have a valid strategy.
                (uint256 activation, , , ) = StrategyManager(strategyManager).strategies(strategy);
                if (activation == 0) {
                    revert InactiveStrategy(strategy);
                }

                // How much should the strategy have.
                (, , uint256 currentDebt, ) = StrategyManager(strategyManager).strategies(strategy);

                // What is the max amount to withdraw from this strategy.
                // NEEDS ATTENTION!!!!
                // ORIGINAL CODE IS MATH.MIN
                // NEEDS TO CAREFUL REVIEW THIS AND TRY TO UNDERSTAND WHAT'S GOING ON HERE
                uint256 assetsToWithdraw = Math.min(state.assetsNeeded, currentDebt);

                // Cache max_withdraw now for use if unrealized loss > 0
                // Use maxRedeem and convert since we use redeem.
                uint256 currMaxWithdraw = IStrategy(strategy).convertToAssets(IStrategy(strategy).maxRedeem(address(this)));

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
                        unrealisedLossesShare = (unrealisedLossesShare * currMaxWithdraw) / wanted;
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
                        IStrategyManager(strategyManager).setDebt(strategy, newDebt);

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
                if (state.currTotalIdle + assetsToWithdraw - loss <= 0) {
                    state.currTotalIdle = 0;
                } else {
                    state.currTotalIdle += assetsToWithdraw - loss;
                }
                if (state.requestedAssets - loss <= 0) {
                    state.requestedAssets = 0;
                } else {
                    state.requestedAssets -= loss;
                }
                if (state.currTotalDebt - assetsToWithdraw <= 0) {
                    state.currTotalDebt = 0;
                } else {
                    state.currTotalDebt -= assetsToWithdraw;
                }

                // Vault will reduce debt because the unrealised loss has been taken by user
                uint256 _newDebt;
                if (currentDebt < (assetsToWithdraw + unrealisedLossesShare)) {
                    _newDebt = 0;
                } else {
                    _newDebt = currentDebt - (assetsToWithdraw + unrealisedLossesShare);
                }

                // Update strategies storage
                IStrategyManager(strategyManager).setDebt(strategy, _newDebt);
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
                revert InsufficientAssets(state.currTotalIdle, state.requestedAssets);
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
            if (assets - requestedAssets > (assets * maxLoss) / MAX_BPS) {
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

    // ## ERC20+4626 compatibility

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

    // @notice Approve an address to spend the vault's shares.
    // @param spender The address to approve.
    // @param amount The amount of shares to approve.
    // @return True if the approval was successful.
    function approve(address spender, uint256 amount) external override returns (bool) {
        return _approve(msg.sender, spender, amount);
    }

    // @notice Convert an amount of shares to assets.
    // @param shares The amount of shares to convert.
    // @return The amount of assets.
    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares, Rounding.ROUND_DOWN);
    }

    // @notice Convert an amount of assets to shares.
    // @param assets The amount of assets to convert.
    // @return The amount of shares.
    function convertToShares(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets, Rounding.ROUND_DOWN);
    }

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

    // @notice Redeems an amount of shares of `owners` shares sending funds to `receiver`.
    // @dev The default behavior is to allow losses to be realized.
    // @param shares The amount of shares to burn.
    // @param receiver The address to receive the assets.
    // @param owner The address who's shares are being burnt.
    // @param maxLoss Optional amount of acceptable loss in Basis Points.
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
        return _redeem(tx.origin, receiver, owner, assets, shares, maxLoss, _strategies);
    }

    // Calculate share management based on gains, losses, and fees.
    function calculateShareManagement(
        uint256 gain,
        uint256 loss,
        uint256 totalFees,
        uint256 protocolFees,
        address strategy
    ) external override returns (ShareManagement memory) {
        // `shares_to_burn` is derived from amounts that would reduce the vaults PPS.
        // NOTE: this needs to be done before any pps changes
        ShareManagement memory shares;

        uint256 currentDebt = IStrategyManager(strategyManager).getDebt(strategy);

        // Record any reported gains.
        if (gain > 0) {
            // NOTE: this will increase totalAssets
            IStrategyManager(strategyManager).setDebt(strategy, currentDebt + gain);
            totalDebtAmount += gain;
        }

        // Strategy is reporting a loss
        if (loss > 0) {
            IStrategyManager(strategyManager).setDebt(strategy, currentDebt - loss);
            totalDebtAmount -= loss;
        }

        // Only need to burn shares if there is a loss or fees.
        if (loss + totalFees > 0) {
            // The amount of shares we will want to burn to offset losses and fees.
            shares.sharesToBurn += _convertToShares(loss + totalFees, Rounding.ROUND_UP);

            // Vault calculates the amount of shares to mint as fees before changing totalAssets / totalSupply.
            if (totalFees > 0) {
                // Accountant fees are total fees - protocol fees.
                shares.accountantFeesShares = _convertToShares(totalFees - protocolFees, Rounding.ROUND_DOWN);
                if (protocolFees > 0) {
                    uint256 numerator = protocolFees * gain;
                    shares.protocolFeesShares = _convertToShares(numerator / 100, Rounding.ROUND_DOWN);
                }
            }
        }

        return shares;
    }

    // Handle the burning and issuing of shares based on the strategy's report.
    function handleShareBurnsAndIssues(
        ShareManagement memory shares,
        FeeAssessment memory _fees,
        uint256 gain
    ) external override returns (uint256 previouslyLockedShares, uint256 newlyLockedShares) {
        // Shares to lock is any amounts that would otherwise increase the vaults PPS.
        uint256 _newlyLockedShares;
        if (_fees.totalRefunds > 0) {
            // Make sure we have enough approval and enough asset to pull.
            _fees.totalRefunds = Math.min(
                _fees.totalRefunds,
                Math.min(ISharesManager(sharesManager).balanceOf(accountant), ISharesManager(sharesManager).allowance(accountant, address(this)))
            );
            // Transfer the refunded amount of asset to the vault.
            _erc20SafeTransferFrom(address(ASSET), accountant, address(this), _fees.totalRefunds);
            // Update storage to increase total assets.
            totalIdleAmount += _fees.totalRefunds;
        }

        // Mint anything we are locking to the vault.
        if (gain + _fees.totalRefunds > 0 && Setters(setters).profitMaxUnlockTime() != 0) {
            _newlyLockedShares = _issueSharesForAmount(gain + _fees.totalRefunds, address(this));
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
            _issueShares(shares.protocolFeesShares, _fees.protocolFeeRecipient);
        }

        return (_previouslyLockedShares, _newlyLockedShares);
    }

    // Manage the unlocking of shares over time based on the vault's configuration.
    function manageUnlockingOfShares(uint256 previouslyLockedShares, uint256 newlyLockedShares) external override {
        // Update unlocking rate and time to fully unlocked.
        uint256 totalLockedShares = previouslyLockedShares + newlyLockedShares;
        if (totalLockedShares > 0) {
            uint256 previouslyLockedTime = 0;
            // Check if we need to account for shares still unlocking.
            if (Setters(setters).fullProfitUnlockDate() > block.timestamp) {
                // There will only be previously locked shares if time remains.
                // We calculate this here since it will not occur every time we lock shares.
                previouslyLockedTime = previouslyLockedShares * (Setters(setters).fullProfitUnlockDate() - block.timestamp);
            }

            // newProfitLockingPeriod is a weighted average between the remaining time of the previously locked shares and the profitMaxUnlockTime
            uint256 newProfitLockingPeriod = (previouslyLockedTime + newlyLockedShares * Setters(setters).profitMaxUnlockTime()) / totalLockedShares;
            // Calculate how many shares unlock per second.
            profitUnlockingRate = (totalLockedShares * MAX_BPS_EXTENDED) / newProfitLockingPeriod;
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

    // @notice Set the new deposit limit.
    // @dev Can not be changed if a deposit_limit_module
    //  is set or if shutdown.
    // @param deposit_limit The new deposit limit.
    function setDepositLimit(uint256 _depositLimit) external override {
        if (shutdown == true) {
            revert StrategyIsShutdown();
        }
        if (depositLimitModule != address(0)) {
            revert UsingModule();
        }
        depositLimit = _depositLimit;
        emit UpdateDepositLimit(_depositLimit);
    }

    function getTotalIdleAmount() external view override returns (uint256) {
        return totalIdleAmount;
    }

    function setTotalIdleAmount(uint256 _totalIdleAmount) external override {
        totalIdleAmount = _totalIdleAmount;
    }

    function getMinimumTotalIdle() external view override returns (uint256) {
        return minimumTotalIdle;
    }

    function setMinimumTotalIdle(uint256 _minimumTotalIdle) external override {
        minimumTotalIdle = _minimumTotalIdle;
    }

    function setTotalDebtAmount(uint256 _totalDebtAmount) external override {
        totalDebtAmount = _totalDebtAmount;
    }

    function depositToStrategy(address strategy, uint256 assetsToDeposit) external override {
        IStrategy(strategy).deposit(assetsToDeposit, address(this));
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../VaultErrors.sol";
import "../VaultStorage.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IVaultInit.sol";
import "../interfaces/IVaultEvents.sol";
import "../interfaces/IDepositLimitModule.sol";
import "../interfaces/IWithdrawLimitModule.sol";
import "../../accountant/interfaces/IAccountant.sol";
import "../../factory/interfaces/IFactory.sol";
import "../../strategy/interfaces/IStrategy.sol";
import { VaultLogic } from "../libs/VaultLogic.sol";

/// @title Fathom Vault
/// @notice The Fathom Vault is designed as a non-opinionated system to distribute funds of
/// depositors for a specific `asset` into different opportunities (aka Strategies)
/// and manage accounting in a robust way.
contract VaultPackage is VaultStorage, IVault, IVaultInit, IVaultEvents {
    using Math for uint256;
    using SafeERC20 for ERC20;

    // solhint-disable-next-line function-max-lines
    function initialize(
        uint256 _profitMaxUnlockTime,
        uint256 _assetType,
        address _asset,
        string calldata _name,
        string calldata _symbol,
        address _accountant, // can be zero
        address _admin
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (initialized == true) {
            revert AlreadyInitialized();
        }

        if (_admin == address(0x00) || _asset == address(0x00)) revert ZeroAddress();

        // Must be less than one year for report cycles
        if (_profitMaxUnlockTime > ONE_YEAR) {
            revert ProfitUnlockTimeTooLong();
        }

        profitMaxUnlockTime = _profitMaxUnlockTime;

        assetContract = ERC20(_asset);
        decimalsValue = assetContract.decimals();

        sharesName = _name;
        sharesSymbol = _symbol;
        factory = msg.sender;
        accountant = _accountant;
        assetType = _assetType;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);

        initialized = true;
    }

    /// @notice Set the new accountant address.
    /// @param newAccountant The new accountant address.
    function setAccountant(address newAccountant) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAccountant == accountant) {
            revert SameAccountant();
        }
        accountant = newAccountant;
        emit UpdatedAccountant(newAccountant);
    }

    /// @notice Set the new default queue array.
    /// @dev Will check each strategy to make sure it is active.
    /// @param newDefaultQueue The new default queue array.
    function setDefaultQueue(address[] calldata newDefaultQueue) external override onlyRole(STRATEGY_MANAGER) {
        uint256 length = newDefaultQueue.length;
        if (length > MAX_QUEUE) {
            revert QueueTooLong();
        }

        // Make sure every strategy in the new queue is active and not duplicated.
        for (uint256 i = 0; i < length; i++) {
            address strategy = newDefaultQueue[i];

            // Check for active strategy.
            if (strategies[strategy].activation == 0) {
                revert InactiveStrategy(strategy);
            }

            // Check for duplicates by comparing with the rest of the queue.
            // Introduces a O(n^2) complexity but the queue is expected to be small.
            for (uint256 j = i + 1; j < length; j++) {
                if (strategy == newDefaultQueue[j]) {
                    revert DuplicateStrategy(strategy);
                }
            }
        }

        // Save the new queue.
        defaultQueue = newDefaultQueue;
        emit UpdatedDefaultQueue(newDefaultQueue);
    }

    /// @notice Set a new value for `use_default_queue`.
    /// @dev If set `True` the default queue will always be
    /// used no matter whats passed in.
    /// @param _useDefaultQueue new value.
    function setUseDefaultQueue(bool _useDefaultQueue) external override onlyRole(STRATEGY_MANAGER) {
        useDefaultQueue = _useDefaultQueue;
        emit UpdatedUseDefaultQueue(_useDefaultQueue);
    }

    /// @notice Set the new deposit limit.
    /// @param _depositLimit The new deposit limit.
    // solhint-disable-next-line code-complexity
    function setDepositLimit(uint256 _depositLimit) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (shutdown == true) {
            revert InactiveVault();
        }
        if (depositLimitModule != address(0)) {
            revert UsingModule();
        }
        if (_depositLimit == 0) {
            revert ZeroValue();
        }

        depositLimit = _depositLimit;
        emit UpdatedDepositLimit(_depositLimit);
    }

    function setMinUserDeposit(uint256 _minUserDeposit) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        minUserDeposit = _minUserDeposit;
        emit UpdatedMinUserDeposit(_minUserDeposit);
    }

    /// @notice Set a contract to handle the deposit limit.
    /// @dev The default `depositLimit` will need to be set to
    /// max uint256 since the module will override it.
    /// @param _depositLimitModule Address of the module.
    function setDepositLimitModule(address _depositLimitModule) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (shutdown == true) {
            revert InactiveVault();
        }
        if (depositLimit != type(uint256).max) {
            revert UsingDepositLimit();
        }
        depositLimitModule = _depositLimitModule;
        emit UpdatedDepositLimitModule(_depositLimitModule);
    }

    /// @notice Set a contract to handle the withdraw limit.
    /// @dev This will override the default `maxWithdraw`.
    /// @param _withdrawLimitModule Address of the module.
    function setWithdrawLimitModule(address _withdrawLimitModule) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        withdrawLimitModule = _withdrawLimitModule;
        emit UpdatedWithdrawLimitModule(_withdrawLimitModule);
    }

    /// @notice Set the new minimum total idle.
    /// @param _minimumTotalIdle The new minimum total idle.
    function setMinimumTotalIdle(uint256 _minimumTotalIdle) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        minimumTotalIdle = _minimumTotalIdle;
        emit UpdatedMinimumTotalIdle(_minimumTotalIdle);
    }

    /// @notice Set the new profit max unlock time.
    /// @dev The time is denominated in seconds and must be less than 1 year.
    ///  We only need to update locking period if setting to 0,
    ///  since the current period will use the old rate and on the next
    ///  report it will be reset with the new unlocking time.
    ///  Setting to 0 will cause any currently locked profit to instantly
    /// unlock and an immediate increase in the vaults Price Per Share.
    /// @param _newProfitMaxUnlockTime The new profit max unlock time.
    function setProfitMaxUnlockTime(uint256 _newProfitMaxUnlockTime) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Must be less than one year for report cycles
        if (_newProfitMaxUnlockTime > ONE_YEAR) {
            revert ProfitUnlockTimeTooLong();
        }

        // If setting to 0 we need to reset any locked values.
        if (_newProfitMaxUnlockTime == 0) {
            // Burn any shares the vault still has.
            _burnShares(sharesBalanceOf[address(this)], address(this));
            // Reset unlocking variables to 0.
            profitUnlockingRate = 0;
            fullProfitUnlockDate = 0;
        }
        profitMaxUnlockTime = _newProfitMaxUnlockTime;
        emit UpdatedProfitMaxUnlockTime(_newProfitMaxUnlockTime);
    }

    /// @notice Add a new strategy.
    /// @param newStrategy The new strategy to add.
    function addStrategy(address newStrategy) external override onlyRole(STRATEGY_MANAGER) {
        if (newStrategy == address(0) || newStrategy == address(this)) {
            revert ZeroAddress();
        }
        address strategyAsset = IStrategy(newStrategy).asset();
        if (strategyAsset != address(assetContract)) {
            revert InvalidAsset(strategyAsset);
        }
        if (strategies[newStrategy].activation != 0) {
            revert StrategyAlreadyActive();
        }

        // Add the new strategy to the mapping.
        strategies[newStrategy] = StrategyParams({ activation: block.timestamp, lastReport: block.timestamp, currentDebt: 0, maxDebt: 0 });

        // If the default queue has space, add the strategy.
        uint256 defaultQueueLength = defaultQueue.length;
        if (defaultQueueLength < MAX_QUEUE) {
            defaultQueue.push(newStrategy);
        }

        emit StrategyChanged(newStrategy, StrategyChangeType.ADDED);
    }

    /// @notice Revoke a strategy.
    /// @param strategy The strategy to revoke.
    function revokeStrategy(address strategy, bool force) external override onlyRole(STRATEGY_MANAGER) {
        _revokeStrategy(strategy, force);
    }

    /// @notice Update the max debt for a strategy.
    /// @param strategy The strategy to update the max debt for.
    /// @param newMaxDebt The new max debt for the strategy.
    function updateMaxDebtForStrategy(address strategy, uint256 newMaxDebt) external override onlyRole(STRATEGY_MANAGER) {
        if (strategies[strategy].activation == 0) {
            revert InactiveStrategy(strategy);
        }
        strategies[strategy].maxDebt = newMaxDebt;
        emit UpdatedMaxDebtForStrategy(msg.sender, strategy, newMaxDebt);
    }

    /// @notice Shutdown the vault.
    function shutdownVault() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (shutdown == true) {
            revert InactiveVault();
        }

        // Shutdown the vault.
        shutdown = true;

        // Set deposit limit to 0.
        if (depositLimitModule != address(0)) {
            depositLimitModule = address(0);
            emit UpdatedDepositLimitModule(address(0));
        }

        depositLimit = 0;
        emit UpdatedDepositLimit(0);
        emit Shutdown();
    }

    /// @notice Process the report of a strategy.
    /// @dev Processing a report means comparing the debt that the strategy has taken
    /// with the current amount of funds it is reporting. If the strategy owes
    /// less than it currently has, it means it has had a profit, else (assets < debt)
    /// it has had a loss.
    /// Different strategies might choose different reporting strategies: pessimistic,
    /// only realised P&L, ... The best way to report depends on the strategy.
    /// The profit will be distributed following a smooth curve over the vaults
    /// profitMaxUnlockTime seconds. Losses will be taken immediately, first from the
    /// profit buffer (avoiding an impact in pps), then will reduce pps.
    /// Any applicable fees are charged and distributed during the report as well
    /// to the specified recipients.
    /// @param strategy The strategy to process the report for.
    /// @return The gain and loss of the strategy.
    function processReport(address strategy) external override onlyRole(REPORTING_MANAGER) nonReentrant returns (uint256, uint256) {
        // Make sure we have a valid strategy.
        if (strategies[strategy].activation == 0) {
            revert InactiveStrategy(strategy);
        }

        // Burn shares that have been unlocked since the last update
        _burnUnlockedShares();

        uint256 currentTotalSupply = _totalSupply();
        uint256 currentTotalAssets = _totalAssets();

        ReportInfo memory report = VaultLogic.processReport(
            strategy,
            strategies[strategy].currentDebt,
            currentTotalSupply,
            currentTotalAssets,
            accountant,
            factory
        );

        _handleShareBurnsAndIssues(report.gain, report.loss, report.shares, report.assessmentFees, strategy);

        // Record the report of profit timestamp.
        strategies[strategy].lastReport = block.timestamp;

        // We have to recalculate the fees paid for cases with an overall loss.
        emit StrategyReported(
            strategy,
            report.gain,
            report.loss,
            strategies[strategy].currentDebt,
            report.protocolFees,
            report.totalFees,
            report.assessmentFees.totalRefunds
        );

        return (report.gain, report.loss);
    }

    /// @notice Update the debt for a strategy.
    /// @param strategy The strategy to update the debt for.
    /// @param newDebt The target debt for the strategy.
    /// @return The amount of debt added or removed.
    // solhint-disable-next-line function-max-lines,code-complexity
    function updateDebt(address strategy, uint256 newDebt) external override onlyRole(STRATEGY_MANAGER) nonReentrant returns (uint256) {
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
            (uint256 withdrawn, uint256 assetsToWithdraw) = VaultLogic.decreaseDebt(
                strategy,
                newDebt,
                currentDebt,
                totalIdle,
                minimumTotalIdle,
                assetContract
            );

            // Update storage.
            totalIdle += withdrawn; // actual amount we got.
            // Amount we tried to withdraw in case of losses
            totalDebt -= assetsToWithdraw;

            newDebt = currentDebt - assetsToWithdraw;
        } else {
            uint256 assetsToDeposit = VaultLogic.increaseDebt(
                strategy,
                strategies[strategy].maxDebt,
                newDebt,
                currentDebt,
                totalIdle,
                minimumTotalIdle
            );

            // Can't Deposit 0.
            if (assetsToDeposit > 0) {
                // actual amount we deposited.
                assetsToDeposit = _depositToStrategy(strategy, assetsToDeposit);

                // Update storage.
                totalIdle -= assetsToDeposit;
                totalDebt += assetsToDeposit;
            }

            newDebt = currentDebt + assetsToDeposit;
        }

        // Commit memory to storage.
        strategies[strategy].currentDebt = newDebt;

        emit DebtUpdated(strategy, currentDebt, newDebt);
        return newDebt;
    }

    /// @notice Used for governance to buy bad debt from the vault.
    /// @dev This should only ever be used in an emergency in place
    /// of force revoking a strategy in order to not report a loss.
    /// It allows the DEBT_PURCHASER role to buy the strategies debt
    /// for an equal amount of `asset`.
    /// @param strategy The strategy to buy the debt for
    /// @param amount The amount of debt to buy from the vault.
    function buyDebt(address strategy, uint256 amount) external override onlyRole(DEBT_PURCHASER) nonReentrant {
        if (strategies[strategy].activation == 0) {
            revert InactiveStrategy(strategy);
        }

        // Cache the current debt.
        uint256 currentDebt = strategies[strategy].currentDebt;

        if (currentDebt == 0 || amount == 0) {
            revert ZeroValue();
        }

        if (amount > currentDebt) {
            amount = currentDebt;
        }

        // We get the proportion of the debt that is being bought and
        // transfer the equivalent shares. We assume this is being used
        // due to strategy issues so won't rely on its conversion rates.
        uint256 shares = (ERC20(strategy).balanceOf(address(this)) * amount) / currentDebt;

        if (shares == 0) {
            revert ZeroValue();
        }

        _erc20SafeTransferFrom(address(assetContract), msg.sender, address(this), amount);

        // Lower strategy debt
        strategies[strategy].currentDebt -= amount;
        // lower total debt
        totalDebt -= amount;
        // Increase total idle
        totalIdle += amount;

        // Log debt change
        emit DebtUpdated(strategy, currentDebt, currentDebt - amount);

        // Transfer the strategies shares out
        _erc20SafeTransfer(strategy, msg.sender, shares);

        // Log the debt purchase
        emit DebtPurchased(strategy, amount);
    }

    /// @notice Withdraw an amount of asset to `receiver` burning `owner`s shares.
    /// @dev The default behavior is to not allow any loss.
    /// @param assets The amount of asset to withdraw.
    /// @param receiver The address to receive the assets.
    /// @param owner The address who's shares are being burnt.
    /// @param maxLoss Optional amount of acceptable loss in Basis Points.
    /// @param _strategies Optional array of strategies to withdraw from.
    /// @return The amount of shares actually burnt.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] calldata _strategies
    ) external override nonReentrant returns (uint256) {
        uint256 shares = VaultLogic.convertToShares(assets, _totalSupply(), _totalAssets(), Rounding.ROUND_UP);
        _redeem(msg.sender, receiver, owner, assets, shares, maxLoss, _strategies);
        return shares;
    }

    /// @notice Redeems an amount of shares of `owners` shares sending funds to `receiver`.
    /// @dev The default behavior is to allow losses to be realized.
    /// @param shares The amount of shares to burn.
    /// @param receiver The address to receive the assets.
    /// @param owner The address who's shares are being burnt.
    /// @param maxLoss Optional amount of acceptable loss in Basis Points.
    /// @param _strategies Optional array of strategies to withdraw from.
    /// @return The amount of assets actually withdrawn.
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss,
        address[] calldata _strategies
    ) external override nonReentrant returns (uint256) {
        // Always return the actual amount of assets withdrawn.
        return
            _redeem(
                msg.sender,
                receiver,
                owner,
                VaultLogic.convertToAssets(shares, _totalSupply(), _totalAssets(), Rounding.ROUND_DOWN),
                shares,
                maxLoss,
                _strategies
            );
    }

    /// @notice Deposit assets into the vault.
    /// @param assets The amount of assets to deposit.
    /// @param receiver The address to receive the shares.
    /// @return The amount of shares minted.
    function deposit(uint256 assets, address receiver) external override nonReentrant returns (uint256) {
        return _deposit(msg.sender, receiver, assets);
    }

    /// @notice Mint shares for the receiver.
    /// @param shares The amount of shares to mint.
    /// @param receiver The address to receive the shares.
    /// @return The amount of assets deposited.
    function mint(uint256 shares, address receiver) external override nonReentrant returns (uint256) {
        return _mint(msg.sender, receiver, shares);
    }

    /// @notice Approve an address to spend the vault's shares.
    /// @param owner The address to approve.
    /// @param spender The address to approve.
    /// @param amount The amount of shares to approve.
    /// @param deadline The deadline for the permit.
    /// @param v The v component of the signature.
    /// @param r The r component of the signature.
    /// @param s The s component of the signature.
    /// @return True if the approval was successful.
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
        nonces[owner]++;

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPE_HASH, owner, spender, amount, nonce, deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));

        address recoveredAddress = ecrecover(digest, v, r, s);
        if (recoveredAddress == address(0) || recoveredAddress != owner) {
            revert ERC20PermitInvalidSignature(recoveredAddress);
        }

        // Set the allowance to the specified amount
        _approve(owner, spender, amount);

        emit Approval(owner, spender, amount);
        return true;
    }

    /// @notice Approve an address to spend the vault's shares.
    /// @param spender The address to approve.
    /// @param amount The amount of shares to approve.
    /// @return True if the approval was successful.
    function approve(address spender, uint256 amount) external override returns (bool) {
        return _approve(msg.sender, spender, amount);
    }

    /// @notice Transfer shares to a receiver.
    /// @param receiver The address to transfer shares to.
    /// @param amount The amount of shares to transfer.
    /// @return True if the transfer was successful.
    function transfer(address receiver, uint256 amount) external override returns (bool) {
        if (receiver == address(this)) {
            revert VaultReceiver();
        }
        _transfer(msg.sender, receiver, amount);
        return true;
    }

    /// @notice Transfer shares from a sender to a receiver.
    /// @param sender The address to transfer shares from.
    /// @param receiver The address to transfer shares to.
    /// @param amount The amount of shares to transfer.
    /// @return True if the transfer was successful.
    function transferFrom(address sender, address receiver, uint256 amount) external override returns (bool) {
        if (receiver == address(this)) {
            revert VaultReceiver();
        }
        _spendAllowance(sender, msg.sender, amount);
        _transfer(sender, receiver, amount);
        return true;
    }

    /// @notice Get the maximum amount of assets that can be withdrawn.
    /// @dev Complies to normal 4626 interface and takes custom params.
    /// @param owner The address that owns the shares.
    /// @param maxLoss Custom maxLoss if any.
    /// @param _strategies Custom strategies queue if any.
    /// @return The maximum amount of assets that can be withdrawn.
    function maxWithdraw(address owner, uint256 maxLoss, address[] calldata _strategies) external view override returns (uint256) {
        return _maxWithdraw(owner, maxLoss, _strategies);
    }

    /// @notice Get the maximum amount of shares that can be redeemed.
    /// @dev Complies to normal 4626 interface and takes custom params.
    /// @param owner The address that owns the shares.
    /// @param maxLoss Custom maxLoss if any.
    /// @param _strategies Custom strategies queue if any.
    /// @return The maximum amount of shares that can be redeemed.
    function maxRedeem(address owner, uint256 maxLoss, address[] calldata _strategies) external view override returns (uint256) {
        uint256 sharesEquivalent = VaultLogic.convertToShares(
            _maxWithdraw(owner, maxLoss, _strategies),
            _totalSupply(),
            _totalAssets(),
            Rounding.ROUND_DOWN
        );
        return Math.min(sharesEquivalent, sharesBalanceOf[owner]);
    }

    /// @notice Get the amount of shares that have been unlocked.
    /// @return The amount of shares that are have been unlocked.
    function unlockedShares() external view override returns (uint256) {
        return _unlockedShares();
    }

    /// @notice Get the price per share (pps) of the vault.
    /// @dev This value offers limited precision. Integrations that require
    /// exact precision should use convertToAssets or convertToShares instead.
    /// @return The price per share.
    function pricePerShare() external view override returns (uint256) {
        return VaultLogic.convertToAssets(10 ** decimalsValue, _totalSupply(), _totalAssets(), Rounding.ROUND_DOWN);
    }

    /// @notice ERC20 - name of the vault's token
    function name() external view override returns (string memory) {
        return sharesName;
    }

    /// @notice ERC20 - symbol of the vault's token
    function symbol() external view override returns (string memory) {
        return sharesSymbol;
    }

    /// @notice Get the total supply of shares.
    /// @return The total supply of shares.
    function totalSupply() external view override returns (uint256) {
        return _totalSupply();
    }

    /// @notice Get the address of the asset.
    /// @return The address of the asset.
    function asset() external view override returns (address) {
        return address(assetContract);
    }

    /// @notice Get the total assets held by the vault.
    /// @return The total assets held by the vault.
    function totalAssets() external view override returns (uint256) {
        return _totalAssets();
    }

    /// @notice Convert an amount of assets to shares.
    /// @param assets The amount of assets to convert.
    /// @return The amount of shares.
    function convertToShares(uint256 assets) external view override returns (uint256) {
        return VaultLogic.convertToShares(assets, _totalSupply(), _totalAssets(), Rounding.ROUND_DOWN);
    }

    /// @notice Convert an amount of shares to assets.
    /// @param shares The amount of shares to convert.
    /// @return The amount of assets.
    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return VaultLogic.convertToAssets(shares, _totalSupply(), _totalAssets(), Rounding.ROUND_DOWN);
    }

    /// @notice Preview the amount of shares that would be minted for a deposit.
    /// @param assets The amount of assets to deposit.
    /// @return The amount of shares that would be minted.
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return VaultLogic.convertToShares(assets, _totalSupply(), _totalAssets(), Rounding.ROUND_DOWN);
    }

    /// @notice Preview the amount of shares that would be redeemed for a withdraw.
    /// @param assets The amount of assets to withdraw.
    /// @return The amount of shares that would be redeemed.
    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return VaultLogic.convertToShares(assets, _totalSupply(), _totalAssets(), Rounding.ROUND_UP);
    }

    /// @notice Preview the amount of assets that would be deposited for a mint.
    /// @param shares The amount of shares to mint.
    /// @return The amount of assets that would be deposited.
    function previewMint(uint256 shares) external view override returns (uint256) {
        return VaultLogic.convertToAssets(shares, _totalSupply(), _totalAssets(), Rounding.ROUND_UP);
    }

    /// @notice Preview the amount of assets that would be withdrawn for a redeem.
    /// @param shares The amount of shares to redeem.
    /// @return The amount of assets that would be withdrawn.
    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return VaultLogic.convertToAssets(shares, _totalSupply(), _totalAssets(), Rounding.ROUND_DOWN);
    }

    /// @notice Get the maximum amount of assets that can be deposited.
    /// @param receiver The address that will receive the shares.
    /// @return The maximum amount of assets that can be deposited.
    function maxDeposit(address receiver) external view override returns (uint256) {
        return _maxDeposit(receiver);
    }

    /// @notice Get the maximum amount of shares that can be minted.
    /// @param receiver The address that will receive the shares.
    /// @return The maximum amount of shares that can be minted.
    function maxMint(address receiver) external view override returns (uint256) {
        return VaultLogic.convertToShares(_maxDeposit(receiver), _totalSupply(), _totalAssets(), Rounding.ROUND_DOWN);
    }

    /// @notice Assess the share of unrealised losses for a strategy.
    /// @param strategy The strategy to assess the share of unrealised losses for.
    /// @param assetsNeeded The amount of assets needed by the strategy.
    function assessShareOfUnrealisedLosses(address strategy, uint256 assetsNeeded) external view override returns (uint256) {
        // Assuming strategies mapping and _assessShareOfUnrealisedLosses are defined
        uint256 strategyCurrentDebt = strategies[strategy].currentDebt;
        if (strategyCurrentDebt < assetsNeeded) {
            revert StrategyDebtIsLessThanAssetsNeeded(strategyCurrentDebt);
        }
        return VaultLogic.assessShareOfUnrealisedLosses(strategy, assetsNeeded, strategyCurrentDebt);
    }

    /// @notice Get default strategy queue length.
    function getDefaultQueueLength() external view override returns (uint256 length) {
        return defaultQueue.length;
    }

    /// @notice Get default strategy queue.
    function getDefaultQueue() external view override returns (address[] memory) {
        return defaultQueue;
    }

    /// @notice Get the number of decimals of the asset/share.
    /// @return The number of decimals of the asset/share.
    function decimals() external view override returns (uint8) {
        return decimalsValue;
    }

    /// @notice Get debt for a strategy.
    /// @param strategy The strategy to withdraw from.
    function getDebt(address strategy) external view override returns (uint256) {
        return strategies[strategy].currentDebt;
    }

    /// @notice Get the allowance for a spender.
    /// @param owner The address that owns the shares.
    /// @param spender The address that is allowed to spend the shares.
    function allowance(address owner, address spender) external view override returns (uint256) {
        return sharesAllowance[owner][spender];
    }

    /// @notice Get the balance of a user.
    /// @param addr The address to get the balance of.
    /// @return The balance of the user.
    function balanceOf(address addr) external view override returns (uint256) {
        if (addr == address(this)) {
            return sharesBalanceOf[addr] - _unlockedShares();
        }
        return sharesBalanceOf[addr];
    }

    /// @notice EIP-2612 permit() domain separator.
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    DOMAIN_TYPE_HASH,
                    keccak256(bytes(sharesName)), // "Fathom Vault" in the example
                    keccak256(bytes(apiVersion())), // API_VERSION in the example
                    block.chainid, // Current chain ID
                    address(this) // Address of the contract
                )
            );
    }

    /// @notice The version of this vault.
    function apiVersion() public pure override returns (string memory) {
        return "1.0.0";
    }

    /// @notice Deposit assets into the strategy.
    function _depositToStrategy(address strategy, uint256 assetsToDeposit) internal returns (uint256 deposited) {
        _erc20SafeApprove(address(assetContract), strategy, assetsToDeposit);

        // Always update based on actual amounts deposited.
        uint256 preBalance = assetContract.balanceOf(address(this));
        IStrategy(strategy).deposit(assetsToDeposit, address(this));
        uint256 postBalance = assetContract.balanceOf(address(this));

        // Make sure our approval is always back to 0.
        _erc20SafeApprove(address(assetContract), strategy, 0);

        // Making sure we are changing according to the real result no
        // matter what. This will spend more gas but makes it more robust.
        deposited = preBalance - postBalance;
    }

    /// @notice Burns shares that have been unlocked since last update.
    /// In case the full unlocking period has passed, it stops the unlocking.
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

    /// @notice Handle the burning and issuing of shares based on the strategy's report.
    // solhint-disable-next-line function-max-lines, code-complexity
    function _handleShareBurnsAndIssues(
        uint256 gain,
        uint256 loss,
        ShareManagement memory shares,
        FeeAssessment memory fees,
        address strategy
    ) internal {
        // Shares to lock is any amounts that would otherwise increase the vaults PPS.
        uint256 _newlyLockedShares;
        if (fees.totalRefunds > 0) {
            // Make sure we have enough approval and enough asset to pull.
            fees.totalRefunds = Math.min(
                fees.totalRefunds,
                Math.min(assetContract.balanceOf(accountant), assetContract.allowance(accountant, address(this)))
            );
            // Transfer the refunded amount of asset to the vault.
            _erc20SafeTransferFrom(address(assetContract), accountant, address(this), fees.totalRefunds);
            // Update storage to increase total assets.
            totalIdle += fees.totalRefunds;
        }

        // Record any reported gains.
        if (gain > 0) {
            // NOTE: this will increase totalAssets
            strategies[strategy].currentDebt += gain;
            totalDebt += gain;
        }

        // Mint anything we are locking to the vault.
        if (gain + fees.totalRefunds > 0 && profitMaxUnlockTime != 0) {
            _newlyLockedShares = _issueSharesForAmount(gain + fees.totalRefunds, address(this));
        }

        // Strategy is reporting a loss
        if (loss > 0) {
            strategies[strategy].currentDebt -= loss;
            totalDebt -= loss;
        }

        // NOTE: should be precise (no new unlocked shares due to above's burn of shares)
        // newlyLockedShares have already been minted / transferred to the vault, so they need to be subtracted
        // no risk of underflow because they have just been minted.
        uint256 _previouslyLockedShares = sharesBalanceOf[address(this)] - _newlyLockedShares;

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

        _manageUnlockingOfShares(_previouslyLockedShares, _newlyLockedShares);
    }

    /// @notice Manage the unlocking of shares over time based on the vault's configuration.
    function _manageUnlockingOfShares(uint256 previouslyLockedShares, uint256 newlyLockedShares) internal {
        // Update unlocking rate and time to fully unlocked.
        uint256 totalLockedShares = previouslyLockedShares + newlyLockedShares;
        if (totalLockedShares > 0) {
            uint256 previouslyLockedTime;
            // Check if we need to account for shares still unlocking.
            if (fullProfitUnlockDate > block.timestamp) {
                // There will only be previously locked shares if time remains.
                // We calculate this here since it will not occur every time we lock shares.
                previouslyLockedTime = previouslyLockedShares * (fullProfitUnlockDate - block.timestamp);
            }

            // newProfitLockingPeriod is a weighted average between the remaining time of the previously locked shares and the profitMaxUnlockTime
            uint256 newProfitLockingPeriod = (previouslyLockedTime + newlyLockedShares * profitMaxUnlockTime) / totalLockedShares;
            // Calculate how many shares unlock per second.
            profitUnlockingRate = (totalLockedShares * MAX_BPS_EXTENDED) / newProfitLockingPeriod;
            // Calculate how long until the full amount of shares is unlocked.
            fullProfitUnlockDate = block.timestamp + newProfitLockingPeriod;
            // Update the last profitable report timestamp.
            lastProfitUpdate = block.timestamp;
        } else {
            // NOTE: only setting this to 0 will turn in the desired effect, no need
            // to update lastProfitUpdate or fullProfitUnlockDate
            profitUnlockingRate = 0;
        }
    }

    /// @notice Approves vault shares to be spent by a spender.
    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        // Unlimited approval does nothing (saves an SSTORE)
        uint256 currentAllowance = sharesAllowance[owner][spender];
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < amount) {
                revert ERC20InsufficientAllowance(currentAllowance);
            }
            _approve(owner, spender, currentAllowance - amount);
        }
    }

    /// @notice Transfers shares from a sender to a receiver.
    function _transfer(address sender, address receiver, uint256 amount) internal {
        if (sharesBalanceOf[sender] < amount) {
            revert InsufficientFunds();
        }
        if (sender == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        if (sender == receiver) {
            revert SelfTransfer();
        }

        sharesBalanceOf[sender] -= amount;
        sharesBalanceOf[receiver] += amount;
        emit Transfer(sender, receiver, amount);
    }

    /// @notice Approves a spender to spend a certain amount of shares.
    function _approve(address owner, address spender, uint256 amount) internal returns (bool) {
        if (owner == address(0) || spender == address(0)) {
            revert ZeroAddress();
        }
        if (owner == spender) {
            revert SelfApprove();
        }
        sharesAllowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
        return true;
    }

    /// @notice Burns shares of the owner.
    function _burnShares(uint256 shares, address owner) internal {
        if (sharesBalanceOf[owner] < shares) {
            revert InsufficientShares(sharesBalanceOf[owner]);
        }
        sharesBalanceOf[owner] -= shares;
        totalSupplyAmount -= shares;
        emit Transfer(owner, address(0), shares);
    }

    /// @notice Used only to approve tokens that are not the type managed by this Vault.
    /// Used to handle non-compliant tokens like USDT
    function _erc20SafeApprove(address token, address spender, uint256 amount) internal {
        if (token == address(0) || spender == address(0)) {
            revert ZeroAddress();
        }
        ERC20(token).safeApprove(spender, amount);
    }

    /// @notice Used only to transfer tokens that are not the type managed by this Vault.
    /// Used to handle non-compliant tokens like USDT
    function _erc20SafeTransferFrom(address token, address sender, address receiver, uint256 amount) internal {
        if (token == address(0) || sender == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        ERC20(token).safeTransferFrom(sender, receiver, amount);
    }

    /// @notice Used only to send tokens that are not the type managed by this Vault.
    /// Used to handle non-compliant tokens like USDT
    function _erc20SafeTransfer(address token, address receiver, uint256 amount) internal {
        if (token == address(0) || receiver == address(0)) {
            revert ZeroAddress();
        }
        ERC20(token).safeTransfer(receiver, amount);
    }

    /// @notice Issues shares that are worth 'amount' in the underlying token (asset).
    /// WARNING: this takes into account that any new assets have been summed
    /// to totalAssets (otherwise pps will go down).
    function _issueShares(uint256 shares, address recipient) internal {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        sharesBalanceOf[recipient] += shares;
        totalSupplyAmount += shares;
        emit Transfer(address(0), recipient, shares);
    }

    /// @notice Issues shares that are worth 'amount' in the underlying token (asset).
    /// WARNING: this takes into account that any new assets have been summed
    /// to totalAssets (otherwise pps will go down).
    function _issueSharesForAmount(uint256 amount, address recipient) internal returns (uint256) {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        uint256 currentTotalSupply = _totalSupply();
        uint256 currentTotalAssets = _totalAssets();
        uint256 newShares;

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

    /// @notice Used for `deposit` calls to transfer the amount of `asset` to the vault,
    /// issue the corresponding shares to the `recipient` and update all needed
    /// vault accounting.
    function _deposit(address sender, address recipient, uint256 assets) internal returns (uint256) {
        uint256 minDepositAmount = minUserDeposit;
        uint256 depositedAssets = VaultLogic.convertToAssets(sharesBalanceOf[recipient], _totalSupply(), _totalAssets(), Rounding.ROUND_DOWN);

        if (depositedAssets + assets < minDepositAmount) {
            revert MinDepositNotReached();
        }

        uint256 _maxDepositAmount = _maxDeposit(recipient);
        if (shutdown == true) {
            revert InactiveVault();
        }
        if (assets == 0) {
            revert ZeroValue();
        }
        if (assets > _maxDepositAmount) {
            revert ExceedDepositLimit(_maxDepositAmount);
        }

        // Case Normal Tokens
        if (assetType == 1) {
            // Transfer the tokens to the vault first.
            _erc20SafeTransferFrom(address(assetContract), sender, address(this), assets);
            // Record the change in total assets.
            totalIdle += assets;

            // Issue the corresponding shares for assets.
            uint256 shares = _issueSharesForAmount(assets, recipient);
            if (shares == 0) {
                revert ZeroValue();
            }

            emit Deposit(sender, recipient, assets, shares);
            return shares;
        } else {
            revert NonCompliantDeposit();
        }
    }

    /// @notice Used for `mint` calls to issue the corresponding shares to the `recipient`,
    /// transfer the amount of `asset` to the vault, and update all needed vault
    /// accounting.
    function _mint(address sender, address recipient, uint256 shares) internal returns (uint256) {
        uint256 _maxDepositAmount = _maxDeposit(recipient);
        if (shutdown == true) {
            revert InactiveVault();
        }
        // Get corresponding amount of assets.
        uint256 assets = VaultLogic.convertToAssets(shares, _totalSupply(), _totalAssets(), Rounding.ROUND_UP);

        if (assets == 0) {
            revert ZeroValue();
        }
        if (assets > _maxDepositAmount) {
            revert ExceedDepositLimit(_maxDepositAmount);
        }

        // Transfer the tokens to the vault first.
        _erc20SafeTransferFrom(address(assetContract), sender, address(this), assets);
        // Record the change in total assets.
        totalIdle += assets;

        // Issue the corresponding shares for assets.
        _issueShares(shares, recipient);

        emit Deposit(sender, recipient, assets, shares);
        return assets;
    }

    /// @notice This will attempt to free up the full amount of assets equivalent to
    /// `sharesToBurn` and transfer them to the `receiver`. If the vault does
    /// not have enough idle funds it will go through any strategies provided by
    /// either the withdrawer or the queueManager to free up enough funds to
    /// service the request.
    /// The vault will attempt to account for any unrealized losses taken on from
    /// strategies since their respective last reports.
    /// Any losses realized during the withdraw from a strategy will be passed on
    /// to the user that is redeeming their vault shares.
    function _redeem(
        address sender,
        address receiver,
        address owner,
        uint256 assets,
        uint256 sharesToBurn,
        uint256 maxLoss,
        address[] memory _strategies
    ) internal returns (uint256) {
        VaultLogic.validateRedeem(receiver, sharesToBurn, maxLoss, MAX_BPS, sharesBalanceOf[owner]);
        uint256 maxWithdrawAmount = _maxWithdraw(owner, maxLoss, _strategies);
        if (assets > maxWithdrawAmount) {
            revert ExceedWithdrawLimit(maxWithdrawAmount);
        }

        uint256 minDepositAmount = minUserDeposit;
        uint256 depositedAssets = VaultLogic.convertToAssets(sharesBalanceOf[owner], _totalSupply(), _totalAssets(), Rounding.ROUND_DOWN);
        uint256 expectedLeftover = depositedAssets - assets;

        if (expectedLeftover > 0 && expectedLeftover < minDepositAmount) {
            revert MinDepositNotReached();
        }

        _handleAllowance(owner, sender, sharesToBurn);
        (uint256 requestedAssets, uint256 currTotalIdle) = _withdrawAssets(assets, _strategies);
        _finalizeRedeem(receiver, owner, sharesToBurn, assets, requestedAssets, currTotalIdle, maxLoss);

        emit Withdraw(sender, receiver, owner, requestedAssets, sharesToBurn);
        return requestedAssets;
    }

    /// @notice Handles the allowance check and spending.
    function _handleAllowance(address owner, address sender, uint256 sharesToBurn) internal {
        if (sender != owner) {
            _spendAllowance(owner, sender, sharesToBurn);
        }
    }

    /// Withdraws assets from strategies as needed and handles unrealized losses.
    // solhint-disable-next-line function-max-lines,code-complexity
    function _withdrawAssets(uint256 assets, address[] memory _strategies) internal returns (uint256, uint256) {
        // Initialize the state struct
        WithdrawalState memory state = WithdrawalState({
            requestedAssets: assets,
            currTotalIdle: totalIdle,
            currTotalDebt: totalDebt,
            assetsNeeded: 0,
            previousBalance: assetContract.balanceOf(address(this)),
            unrealisedLossesShare: 0
        });

        // If there are not enough assets in the Vault contract, we try to free
        // funds from strategies.
        if (state.requestedAssets > state.currTotalIdle) {
            // Cache the default queue.
            // If a custom queue was passed, and we don't force the default queue.
            // Use the custom queue.
            address[] memory currentStrategies = _strategies.length != 0 && !useDefaultQueue ? _strategies : defaultQueue;

            // Withdraw from strategies only what idle doesn't cover.
            // `assetsNeeded` is the total amount we need to fill the request.
            state.assetsNeeded = state.requestedAssets - state.currTotalIdle;

            // Assuming _strategies is an array of addresses representing the strategies
            for (uint256 i = 0; i < currentStrategies.length; i++) {
                address strategy = currentStrategies[i];
                // Make sure we have a valid strategy.
                uint256 activation = strategies[strategy].activation;
                if (activation == 0) {
                    revert InactiveStrategy(strategy);
                }

                // How much should the strategy have.
                uint256 currentDebt = strategies[strategy].currentDebt;

                // NOTE: What is the max amount to withdraw from this strategy is defined by min of asset need and debt.
                uint256 assetsToWithdraw = Math.min(state.assetsNeeded, currentDebt);

                // Cache max_withdraw now for use if unrealized loss > 0
                // Use maxRedeem and convert since we use redeem.
                uint256 currMaxWithdraw = IStrategy(strategy).convertToAssets(IStrategy(strategy).maxRedeem(address(this)));

                // If unrealised losses > 0, then the user will take the proportional share
                // and realize it (required to avoid users withdrawing from lossy strategies).
                // NOTE: strategies need to manage the fact that realising part of the loss can
                // mean the realisation of 100% of the loss!! (i.e. if for withdrawing 10% of the
                // strategy it needs to unwind the whole position, generated losses might be bigger)
                uint256 unrealisedLossesShare = VaultLogic.assessShareOfUnrealisedLosses(strategy, assetsToWithdraw, currentDebt);
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
                VaultLogic.withdrawFromStrategy(strategy, assetsToWithdraw);
                uint256 postBalance = assetContract.balanceOf(address(this));

                // Always check withdrawn against the real amounts.
                uint256 withdrawn = postBalance - state.previousBalance;
                uint256 loss;

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
                revert InsufficientAssets(state.currTotalIdle, state.requestedAssets);
            }

            // Commit memory to storage.
            totalDebt = state.currTotalDebt;
        }

        return (state.requestedAssets, state.currTotalIdle);
    }

    /// @notice Finalizes the redeem operation by burning shares and transferring assets.
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
        totalIdle = currTotalIdle - requestedAssets;
        // Transfer the requested amount to the receiver.
        _erc20SafeTransfer(address(assetContract), receiver, requestedAssets);
    }

    /// @notice Revokes a strategy from the vault.
    // solhint-disable-next-line code-complexity
    function _revokeStrategy(address strategy, bool force) internal {
        if (strategies[strategy].activation == 0) {
            revert InactiveStrategy(strategy);
        }

        // If force revoking a strategy, it will cause a loss.
        uint256 loss;
        if (strategies[strategy].currentDebt != 0) {
            if (!force) revert StrategyHasDebt(strategies[strategy].currentDebt);
            // Vault realizes the full loss of outstanding debt.
            loss = strategies[strategy].currentDebt;
            // Adjust total vault debt.
            totalDebt -= loss;
            emit StrategyReported(strategy, 0, loss, 0, 0, 0, 0);
        }

        // Set strategy params all back to 0 (WARNING: it can be re-added).
        strategies[strategy] = StrategyParams({ activation: 0, lastReport: 0, currentDebt: 0, maxDebt: 0 });

        // Remove strategy if it is in the default queue.
        uint256 defaultQueueLength = defaultQueue.length;
        if (defaultQueueLength > 0) {
            for (uint256 i = 0; i < defaultQueueLength; i++) {
                if (defaultQueue[i] == strategy) {
                    // Shift all elements down one position from the point of removal
                    for (uint256 j = i; j < defaultQueueLength - 1; j++) {
                        defaultQueue[j] = defaultQueue[j + 1];
                    }
                    // Remove the last element by reducing the array length
                    defaultQueue.pop();
                    break; // Exit the loop as we've found and removed the strategy
                }
            }
        }

        emit StrategyChanged(strategy, StrategyChangeType.REVOKED);
    }

    /// @dev Returns the max amount of `asset` an `owner` can withdraw.
    /// This will do a full simulation of the withdraw in order to determine
    /// how much is currently liquid and if the `maxLoss` would allow for the
    /// tx to not revert.
    /// This will track any expected loss to check if the tx will revert, but
    /// not account for it in the amount returned since it is unrealised and
    /// therefore will not be accounted for in the conversion rates.
    /// i.e. If we have 100 debt and 10 of unrealised loss, the max we can get
    /// out is 90, but a user of the vault will need to call withdraw with 100
    /// in order to get the full 90 out.
    // solhint-disable-next-line function-max-lines,code-complexity
    function _maxWithdraw(address owner, uint256 _maxLoss, address[] memory _strategies) internal view returns (uint256) {
        // Get the max amount for the owner if fully liquid.
        uint256 maxAssets = VaultLogic.convertToAssets(sharesBalanceOf[owner], _totalSupply(), _totalAssets(), Rounding.ROUND_DOWN);

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
            uint256 loss;

            // Cache the default queue.
            // If a custom queue was passed, and we don't force the default queue.
            // Use the custom queue.
            address[] memory currentStrategies = _strategies.length != 0 && !useDefaultQueue ? _strategies : defaultQueue;

            for (uint256 i = 0; i < currentStrategies.length; i++) {
                address strategy = currentStrategies[i];
                uint256 currentDebt = strategies[strategy].currentDebt;
                // Can't use an invalid strategy.
                if (strategies[strategy].activation == 0) {
                    revert InactiveStrategy(strategy);
                }

                // Get the maximum amount the vault would withdraw from the strategy.
                uint256 toWithdraw = Math.min(
                    maxAssets - have, // What we still need for the full withdraw
                    currentDebt // The current debt the strategy has.
                );

                // Get any unrealised loss for the strategy.
                uint256 unrealisedLoss = VaultLogic.assessShareOfUnrealisedLosses(strategy, toWithdraw, currentDebt);

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

    /// @notice Returns the amount of shares that have been unlocked.
    /// To avoid sudden pricePerShare spikes, profits must be processed
    /// through an unlocking period. The mechanism involves shares to be
    /// minted to the vault which are unlocked gradually over time. Shares
    /// that have been locked are gradually unlocked over profitMaxUnlockTime.
    function _unlockedShares() internal view returns (uint256) {
        uint256 currUnlockedShares;
        if (fullProfitUnlockDate > block.timestamp) {
            // If we have not fully unlocked, we need to calculate how much has been.
            currUnlockedShares = (profitUnlockingRate * (block.timestamp - lastProfitUpdate)) / MAX_BPS_EXTENDED;
        } else if (fullProfitUnlockDate != 0) {
            // All shares have been unlocked
            currUnlockedShares = sharesBalanceOf[address(this)];
        }
        return currUnlockedShares;
    }

    /// @notice Need to account for the shares issued to the vault that have unlocked.
    function _totalSupply() internal view returns (uint256) {
        return totalSupplyAmount - _unlockedShares();
    }

    /// @notice Total amount of assets that are in the vault and in the strategies.
    function _totalAssets() internal view returns (uint256) {
        return totalIdle + totalDebt;
    }

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
        if (currentTotalAssets >= depositLimit) {
            return 0;
        }

        return depositLimit - currentTotalAssets;
    }
}

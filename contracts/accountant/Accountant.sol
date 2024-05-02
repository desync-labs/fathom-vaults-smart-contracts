// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.19;

import {IVault} from "../vault/interfaces/IVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAccountant.sol";

/// @title Accountant.
/// @dev Will charge fees, issue refunds, and run health check on any reported
///     gains or losses during a strategy's report.
contract Accountant is IAccountant {
    using SafeERC20 for ERC20;

    /// @notice Enum defining change types (added or removed).
    enum ChangeType {
        NULL,
        ADDED,
        REMOVED
    }

    /// @notice Struct representing fee details.
    struct Fee {
        uint16 managementFee; // Annual management fee to charge.
        uint16 performanceFee; // Performance fee to charge.
        uint16 refundRatio; // Refund ratio to give back on losses.
        uint16 maxFee; // Max fee allowed as a percent of gain.
        uint16 maxGain; // Max percent gain a strategy can report.
        uint16 maxLoss; // Max percent loss a strategy can report.
        bool custom; // Flag to set for custom configs.
    }

    /// @notice Constant defining the maximum basis points.
    uint256 internal constant MAX_BPS = 10_000;

    /// @notice Constant defining the number of seconds in a year.
    uint256 internal constant SECS_PER_YEAR = 31_556_952;

    /// @notice Constant defining the management fee threshold.
    uint16 public constant MANAGEMENT_FEE_THRESHOLD = 200;

    /// @notice Constant defining the performance fee threshold.
    uint16 public constant PERFORMANCE_FEE_THRESHOLD = 5_000;

    /// @notice The amount of max loss to use when redeeming from vaults.
    uint256 public maxLoss;

    /// @notice The address of the fee manager.
    address public feeManager;

    /// @notice The address of the fee recipient.
    address public feeRecipient;

    /// @notice An address that can add or remove vaults.
    address public vaultManager;

    /// @notice The address of the future fee manager.
    address public futureFeeManager;

    /// @notice The default fee configuration.
    Fee public defaultConfig;

    /// @notice Mapping to track added vaults.
    mapping(address => bool) public vaults;

    /// @notice Mapping vault => custom Fee config if any.
    mapping(address => Fee) public customConfig;

    /// @notice Mapping vault => strategy => flag for one time healthcheck skips.
    mapping(address => mapping(address => bool)) skipHealthCheck;

    modifier onlyFeeManager() {
        _checkFeeManager();
        _;
    }

    modifier onlyVaultOrFeeManager() {
        _checkVaultOrFeeManager();
        _;
    }

    modifier onlyFeeManagerOrRecipient() {
        _checkFeeManagerOrRecipient();
        _;
    }

    modifier onlyAddedVaults() {
        _checkVaultIsAdded();
        _;
    }

    constructor(
        address _feeManager,
        address _feeRecipient,
        uint16 defaultManagement,
        uint16 defaultPerformance,
        uint16 defaultRefund,
        uint16 defaultMaxFee,
        uint16 defaultMaxGain,
        uint16 defaultMaxLoss
    ) {
        if (_feeManager == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }

        feeManager = _feeManager;
        feeRecipient = _feeRecipient;

        _updateDefaultConfig(
            defaultManagement,
            defaultPerformance,
            defaultRefund,
            defaultMaxFee,
            defaultMaxGain,
            defaultMaxLoss
        );
    }

    /**
     * @notice Function to add a new vault for this accountant to charge fees for.
     * @dev This is not used to set any of the fees for the specific vault or strategy. Each fee will be set separately.
     * @param vault The address of a vault to allow to use this accountant.
     */
    function addVault(address vault) external override virtual onlyVaultOrFeeManager {
        // Ensure the vault has not already been added.
        if (vaults[vault]) {
            revert VaultAlreadyAdded();
        }

        vaults[vault] = true;

        emit VaultChanged(vault, ChangeType.ADDED);
    }

    /**
     * @notice Function to remove a vault from this accountant's fee charging list.
     * @param vault The address of the vault to be removed from this accountant.
     */
    function removeVault(address vault) external override virtual onlyVaultOrFeeManager {
        // Ensure the vault has been previously added.
        if (!vaults[vault]) {
            revert VaultNotFound();
        }

        address asset = IVault(vault).asset();
        // Remove any allowances left.
        if (ERC20(asset).allowance(address(this), vault) != 0) {
            ERC20(asset).safeApprove(vault, 0);
        }

        vaults[vault] = false;

        emit VaultChanged(vault, ChangeType.REMOVED);
    }

    /**
     * @notice Function to update the default fee configuration used for 
        all strategies that don't have a custom config set.
     * @param defaultManagement Default annual management fee to charge.
     * @param defaultPerformance Default performance fee to charge.
     * @param defaultRefund Default refund ratio to give back on losses.
     * @param defaultMaxFee Default max fee to allow as a percent of gain.
     * @param defaultMaxGain Default max percent gain a strategy can report.
     * @param defaultMaxLoss Default max percent loss a strategy can report.
     */
    function updateDefaultConfig(
        uint16 defaultManagement,
        uint16 defaultPerformance,
        uint16 defaultRefund,
        uint16 defaultMaxFee,
        uint16 defaultMaxGain,
        uint16 defaultMaxLoss
    ) external override virtual onlyFeeManager {
        _updateDefaultConfig(
            defaultManagement,
            defaultPerformance,
            defaultRefund,
            defaultMaxFee,
            defaultMaxGain,
            defaultMaxLoss
        );
    }

    /**
     * @notice Function to set a custom fee configuration for a specific vault.
     * @param vault The vault the strategy is hooked up to.
     * @param customManagement Custom annual management fee to charge.
     * @param customPerformance Custom performance fee to charge.
     * @param customRefund Custom refund ratio to give back on losses.
     * @param customMaxFee Custom max fee to allow as a percent of gain.
     * @param customMaxGain Custom max percent gain a strategy can report.
     * @param customMaxLoss Custom max percent loss a strategy can report.
     */
    function setCustomConfig(
        address vault,
        uint16 customManagement,
        uint16 customPerformance,
        uint16 customRefund,
        uint16 customMaxFee,
        uint16 customMaxGain,
        uint16 customMaxLoss
    ) external override virtual onlyFeeManager {
        // Ensure the vault has been added.
        if (!vaults[vault]) {
            revert VaultNotFound();
        }
        // Check for threshold and limit conditions.
        if (customManagement > MANAGEMENT_FEE_THRESHOLD || customPerformance > PERFORMANCE_FEE_THRESHOLD || customMaxLoss > MAX_BPS) {
            revert ValueTooHigh();
        }

        // Create the vault's custom config.
        Fee memory _config = Fee({
            managementFee: customManagement,
            performanceFee: customPerformance,
            refundRatio: customRefund,
            maxFee: customMaxFee,
            maxGain: customMaxGain,
            maxLoss: customMaxLoss,
            custom: true
        });

        // Store the config.
        customConfig[vault] = _config;

        emit UpdateCustomFeeConfig(vault, _config);
    }

    /**
     * @notice Function to remove a previously set custom fee configuration for a vault.
     * @param vault The vault to remove custom setting for.
     */
    function removeCustomConfig(address vault) external override virtual onlyFeeManager {
        // Ensure custom fees are set for the specified vault.
        if (!customConfig[vault].custom) {
            revert NoCustomFeesSet();
        }

        // Set all the vaults's custom fees to 0.
        delete customConfig[vault];

        // Emit relevant event.
        emit RemovedCustomFeeConfig(vault);
    }

    /**
     * @notice Turn off the health check for a specific `vault` `strategy` combo.
     * @dev This will only last for one report and get automatically turned back on.
     * @param vault Address of the vault.
     * @param strategy Address of the strategy.
     */
    function turnOffHealthCheck(
        address vault,
        address strategy
    ) external override virtual onlyFeeManager {
        // Ensure the vault has been added.
        if (!vaults[vault]) {
            revert VaultNotFound();
        }

        skipHealthCheck[vault][strategy] = true;
    }

    /**
     * @notice Function to redeem the underlying asset from a vault.
     * @dev Will default to using the full balance of the vault.
     * @param vault The vault to redeem from.
     */
    function redeemUnderlying(address vault) external override virtual {
        redeemUnderlying(vault, IVault(vault).balanceOf(address(this)));
    }

    /**
     * @notice Sets the `maxLoss` parameter to be used on redeems.
     * @param _maxLoss The amount in basis points to set as the maximum loss.
     */
    function setMaxLoss(uint256 _maxLoss) external override virtual onlyFeeManager {
        // Ensure that the provided `maxLoss` does not exceed 100% (in basis points).
        if (_maxLoss > MAX_BPS) {
            revert ValueTooHigh();
        }

        maxLoss = _maxLoss;

        // Emit an event to signal the update of the `maxLoss` parameter.
        emit UpdateMaxLoss(_maxLoss);
    }

    /**
     * @notice Function to distribute all accumulated fees to the designated recipient.
     * @param token The token to distribute.
     */
    function distribute(address token) external override virtual {
        distribute(token, ERC20(token).balanceOf(address(this)));
    }

    /**
     * @notice Function to set a future fee manager address.
     * @param _futureFeeManager The address to set as the future fee manager.
     */
    function setFutureFeeManager(
        address _futureFeeManager
    ) external override virtual onlyFeeManager {
        // Ensure the futureFeeManager is not a zero address.
        if (_futureFeeManager == address(0)) {
            revert ZeroAddress();
        }
        futureFeeManager = _futureFeeManager;

        emit SetFutureFeeManager(_futureFeeManager);
    }

    /**
     * @notice Function to accept the role change and become the new fee manager.
     * @dev This function allows the future fee manager to accept the role change and become the new fee manager.
     */
    function acceptFeeManager() external override virtual {
        // Make sure the sender is the future fee manager.
        if (msg.sender != futureFeeManager) {
            revert NotFutureFeeManager();
        }
        feeManager = futureFeeManager;
        futureFeeManager = address(0);

        emit NewFeeManager(msg.sender);
    }

    /**
     * @notice Function to set a new vault manager.
     * @param newVaultManager Address to add or remove vaults.
     */
    function setVaultManager(
        address newVaultManager
    ) external override virtual onlyFeeManager {
        vaultManager = newVaultManager;

        emit UpdateVaultManager(newVaultManager);
    }

    /**
     * @notice Function to set a new address to receive distributed rewards.
     * @param newFeeRecipient Address to receive distributed fees.
     */
    function setFeeRecipient(
        address newFeeRecipient
    ) external override virtual onlyFeeManager {
        // Ensure the newFeeRecipient is not a zero address.
        if (newFeeRecipient == address(0)) {
            revert ZeroAddress();
        }
        address oldRecipient = feeRecipient;
        feeRecipient = newFeeRecipient;

        emit UpdateFeeRecipient(oldRecipient, newFeeRecipient);
    }

    /**
     * @notice Public getter to check for custom setting.
     * @dev We use uint256 for the flag since its cheaper so this
     *   will convert it to a bool for easy view functions.
     *
     * @param vault Address of the vault.
     * @return If a custom fee config is set.
     */
    function useCustomConfig(
        address vault
    ) external view override virtual returns (bool) {
        return customConfig[vault].custom;
    }

    /**
     * @notice Get the full config used for a specific `vault`.
     * @param vault Address of the vault.
     * @return fee The config that would be used during the report.
     */
    function getVaultConfig(
        address vault
    ) external view override returns (Fee memory fee) {
        fee = customConfig[vault];

        // Check if there is a custom config to use.
        if (!fee.custom) {
            // Otherwise use the default.
            fee = defaultConfig;
        }
    }

    /**
     * @notice Called by a vault when a `strategy` is reporting.
     * @dev The msg.sender must have been added to the `vaults` mapping.
     * @param strategy Address of the strategy reporting.
     * @param gain Amount of the gain if any.
     * @param loss Amount of the loss if any.
     * @return totalFees if any to charge.
     * @return totalRefunds if any for the vault to pull.
     */
    // solhint-disable-next-line code-complexity, function-max-lines
    function report(
        address strategy,
        uint256 gain,
        uint256 loss
    )
        public
        override
        virtual
        onlyAddedVaults
        returns (uint256 totalFees, uint256 totalRefunds)
    {
        // Declare the config to use as the custom.
        Fee memory fee = customConfig[msg.sender];

        // Check if there is a custom config to use.
        if (!fee.custom) {
            // Otherwise use the default.
            fee = defaultConfig;
        }

        // Retrieve the strategy's params from the vault.
        IVault.StrategyParams memory strategyParams = IVault(msg.sender)
            .strategies(strategy);

        // Charge management fees no matter gain or loss.
        if (fee.managementFee > 0) {
            // Time since the last harvest.
            uint256 duration = block.timestamp - strategyParams.last_report;
            // managementFee is an annual amount, so charge based on the time passed.
            totalFees = ((strategyParams.current_debt *
                duration *
                (fee.managementFee)) /
                MAX_BPS /
                SECS_PER_YEAR);
        }

        // Only charge performance fees if there is a gain.
        if (gain > 0) {
            // If we are skipping the healthcheck this report
            if (skipHealthCheck[msg.sender][strategy]) {
                // Make sure it is reset for the next one.
                skipHealthCheck[msg.sender][strategy] = false;

                // Setting `maxGain` to 0 will disable the healthcheck on profits.
            } else if (fee.maxGain > 0) {
                if (gain > (strategyParams.current_debt * fee.maxGain) / MAX_BPS) {
                    revert TooMuchGain();
                }
            }

            totalFees += (gain * (fee.performanceFee)) / MAX_BPS;
        } else {
            // If we are skipping the healthcheck this report
            if (skipHealthCheck[msg.sender][strategy]) {
                // Make sure it is reset for the next one.
                skipHealthCheck[msg.sender][strategy] = false;

                // Setting `maxLoss` to 10_000 will disable the healthcheck on losses.
            } else if (fee.maxLoss < MAX_BPS) {
                if (loss > (strategyParams.current_debt * fee.maxLoss) / MAX_BPS) {
                    revert TooMuchLoss();
                }
            }

            // Means we should have a loss.
            if (fee.refundRatio > 0) {
                // Cache the underlying asset the vault uses.
                address asset = IVault(msg.sender).asset();
                // Give back either all we have or based on the refund ratio.
                totalRefunds = Math.min(
                    (loss * (fee.refundRatio)) / MAX_BPS,
                    ERC20(asset).balanceOf(address(this))
                );

                if (totalRefunds > 0) {
                    // Approve the vault to pull the underlying asset.
                    _checkAllowance(msg.sender, asset, totalRefunds);
                }
            }
        }

        // 0 Max fee means it is not enforced.
        if (fee.maxFee > 0) {
            // Ensure fee does not exceed the maxFee %.
            totalFees = Math.min((gain * (fee.maxFee)) / MAX_BPS, totalFees);
        }

        return (totalFees, totalRefunds);
    }

    /**
     * @notice Function to redeem the underlying asset from a vault.
     * @param vault The vault to redeem from.
     * @param amount The amount in vault shares to redeem.
     */
    function redeemUnderlying(
        address vault,
        uint256 amount
    ) public override virtual onlyFeeManager {
        IVault(vault).redeem(amount, address(this), address(this), maxLoss);
    }

    /**
     * @notice Function to distribute accumulated fees to the designated recipient.
     * @param token The token to distribute.
     * @param amount amount of token to distribute.
     */
    function distribute(
        address token,
        uint256 amount
    ) public override virtual onlyFeeManagerOrRecipient {
        ERC20(token).safeTransfer(feeRecipient, amount);

        emit DistributeRewards(token, amount);
    }

    /**
     * @dev Internal safe function to make sure the contract you want to
     * interact with has enough allowance to pull the desired tokens.
     *
     * @param _contract The address of the contract that will move the token.
     * @param _token The ERC-20 token that will be getting spent.
     * @param _amount The amount of `_token` to be spent.
     */
    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        if (ERC20(_token).allowance(address(this), _contract) < _amount) {
            ERC20(_token).safeApprove(_contract, 0);
            ERC20(_token).safeApprove(_contract, _amount);
        }
    }

    /**
     * @dev Updates the Accountant's default fee config.
     *   Is used during deployment and during any future updates.
     */
    function _updateDefaultConfig(
        uint16 defaultManagement,
        uint16 defaultPerformance,
        uint16 defaultRefund,
        uint16 defaultMaxFee,
        uint16 defaultMaxGain,
        uint16 defaultMaxLoss
    ) internal virtual {
        // Check for threshold and limit conditions.
        if (defaultManagement > MANAGEMENT_FEE_THRESHOLD || defaultPerformance > PERFORMANCE_FEE_THRESHOLD || defaultMaxLoss > MAX_BPS) {
            revert ValueTooHigh();
        }

        // Update the default fee configuration.
        defaultConfig = Fee({
            managementFee: defaultManagement,
            performanceFee: defaultPerformance,
            refundRatio: defaultRefund,
            maxFee: defaultMaxFee,
            maxGain: defaultMaxGain,
            maxLoss: defaultMaxLoss,
            custom: false
        });

        emit UpdateDefaultFeeConfig(defaultConfig);
    }

    function _checkFeeManager() internal view virtual {
        if (msg.sender != feeManager) {
            revert Unauthorized();
        }
    }

    function _checkVaultOrFeeManager() internal view virtual {
        if (msg.sender != feeManager && msg.sender != vaultManager) {
            revert Unauthorized();
        }
    }

    function _checkFeeManagerOrRecipient() internal view virtual {
        if (msg.sender != feeManager && msg.sender != feeRecipient) {
            revert Unauthorized();
        }
    }

    function _checkVaultIsAdded() internal view virtual {
        if (!vaults[msg.sender]) {
            revert VaultNotFound();
        }
    }
}
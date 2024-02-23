// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023
pragma solidity 0.8.19;

import "../BaseStrategy.sol";
import "./UniswapV3Swapper.sol";
import "./interfaces/IRewardsController.sol";
import "./interfaces/ILender.sol";
import { IPool } from "./interfaces/IPool.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IAToken } from "./interfaces/IAToken.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract AaveV3Lender is BaseStrategy, UniswapV3Swapper, ILender {
    using SafeERC20 for ERC20;

    // The pool to deposit and withdraw through.
    IPool public immutable LENDING_POOL;
    // To get the Supply cap of an asset.
    uint256 internal constant SUPPLY_CAP_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFF000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFF; // prettier-ignore
    uint256 internal constant SUPPLY_CAP_START_BIT_POSITION = 116;
    uint256 internal immutable DECIMALS;
    // The a Token specific rewards contract for claiming rewards.
    IRewardsController public rewardsController;
    // The token that we get in return for deposits.
    IAToken public immutable A_TOKEN;
    // Bool to decide to try and claim rewards. Defaults to True.
    bool public claimRewards = true;
    // Mapping to be set by management for any reward tokens.
    // This can be used to set different mins for different tokens
    // or to set to uint256.max if selling a reward token is reverting
    // to allow for reports to still work properly.
    mapping(address => uint256) public minAmountToSellMapping;

    constructor(
        address _asset,
        string memory _name,
        address _tokenizedStrategyAddress,
        address _lendingPool,
        address _base,
        address _router
    ) BaseStrategy(_asset, _name, _tokenizedStrategyAddress) {
        // Set the lending pool.
        LENDING_POOL = IPool(_lendingPool);        
        // Set the aToken based on the asset we are using.
        A_TOKEN = IAToken(LENDING_POOL.getReserveData(_asset).aTokenAddress);

        // Make sure its a real token.
        require(address(A_TOKEN) != address(0), "!aToken");

        // Get aToken decimals for supply caps.
        DECIMALS = ERC20(address(A_TOKEN)).decimals();
        // Set the rewards controller
        rewardsController = A_TOKEN.getIncentivesController();
        // Make approve the lending pool for cheaper deposits.
        asset.safeApprove(address(LENDING_POOL), type(uint256).max);
        // Set uni swapper values
        // We will use the minAmountToSell mapping instead.
        base = _base;
        router = _router;
    }

    /// @notice Set the uni fees for swaps.
    /// @dev External function available to management to set
    ///     the fees used in the `UniswapV3Swapper.
    ///     Any incentivized tokens will need a fee to be set for each
    ///     reward token that it wishes to swap on reports.
    /// @param _token0 The first token of the pair.
    /// @param _token1 The second token of the pair.
    /// @param _fee The fee to be used for the pair.
    function setUniFees(
        address _token0,
        address _token1,
        uint24 _fee
    ) external override onlyManagement {
        require(_fee < type(uint256).max, "Fee too high");
        _setUniFees(_token0, _token1, _fee);
    }

    /// @notice Allows `management` to manually swap a token the strategy holds.
    /// @dev This can be used if the rewards controller has since removed a reward
    ///     token so the normal harvest flow doesn't work, for retroactive airdrops.
    ///     or just to slowly sell tokens at specific times rather than during harvests.
    /// @param _token The address of the token to sell.
    /// @param _amount The amount of `_token` to sell.
    /// @param _minAmountOut The minimum of `asset` to get out.
    function sellRewardManually(
        address _token,
        uint256 _amount,
        uint256 _minAmountOut
    ) external override onlyManagement {
        _swapFrom(
            _token,
            address(asset),
            Math.min(_amount, ERC20(_token).balanceOf(address(this))),
            _minAmountOut
        );
    }

    /// @notice Set the `minAmountToSellMapping` for a specific `_token`.
    /// @dev This can be used by management to adjust wether or not the
    ///     _claimAndSellRewards() function will attempt to sell a specific
    ///     reward token. This can be used if liquidity is to low, amounts
    ///     are to low or any other reason that may cause reverts.
    /// @param _token The address of the token to adjust.
    /// @param _amount Min required amount to sell.
    function setMinAmountToSellMapping(
        address _token,
        uint256 _amount
    ) external override onlyManagement {
        require(_amount < type(uint256).max, "Amount too high");
        minAmountToSellMapping[_token] = _amount;
    }

    /// @notice Set wether or not the strategy should claim and sell rewards.
    /// @param _bool Wether or not rewards should be claimed and sold
    function setClaimRewards(bool _bool) external override onlyManagement {
        claimRewards = _bool;
    }

    function setRewardsController(address _rewardsController)
        external
        override
        onlyManagement
    {
        rewardsController = IRewardsController(_rewardsController);
    }

    /// @notice Gets the max amount of `asset` that an address can deposit.
    /// @dev Defaults to an unlimited amount for any address. But can
    ///     be overridden by strategists.
    ///
    /// This function will be called before any deposit or mints to enforce
    ///     any limits desired by the strategist. This can be used for either a
    ///     traditional deposit limit or for implementing a whitelist etc.
    /// EX:
    ///     if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
    ///
    /// This does not need to take into account any conversion rates
    ///     from shares to assets. But should know that any non max uint256
    ///     amounts may be converted to shares. So it is recommended to keep
    ///     custom amounts low enough as not to cause overflow when multiplied
    ///     by `totalSupply`.
    /// @param . The address that is depositing into the strategy.
    /// @return . The available amount the `_owner` can deposit in terms of `asset`
    function availableDepositLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        uint256 supplyCap = getSupplyCap();

        // If we have no supply cap.
        if (supplyCap == 0) return type(uint256).max;

        uint256 supply = A_TOKEN.totalSupply();

        // If we already hit the cap.
        if (supplyCap <= supply) return 0;

        // Return the remaining room.
        return supplyCap - supply;
    }

    /// @notice Gets the supply cap of the reserve
    /// @return The supply cap
    function getSupplyCap() public view override returns (uint256) {
        // Get the bit map data config.
        uint256 data = LENDING_POOL
            .getReserveData(address(asset))
            .configuration
            .data;

        // Get out the supply cap for the asset.
        uint256 cap = (data & ~SUPPLY_CAP_MASK) >>
            SUPPLY_CAP_START_BIT_POSITION;

        // Adjust to the correct decimals.
        return cap * (10 ** DECIMALS);
    }

    /// @notice Gets the max amount of `asset` that can be withdrawn.
    /// @dev Defaults to an unlimited amount for any address. But can
    ///     be overridden by strategists.
    ///
    /// This function will be called before any withdraw or redeem to enforce
    ///     any limits desired by the strategist. This can be used for illiquid
    ///     or sandwichable strategies. It should never be lower than `totalIdle`.
    ///
    /// EX:
    ///         return TokenIzedStrategy.totalIdle();
    ///
    /// This does not need to take into account the `_owner`'s share balance
    ///     or conversion rates from shares to assets.
    /// @param . The address that is withdrawing from the strategy.
    /// @return . The available amount that can be withdrawn in terms of `asset`
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        return TokenizedStrategy.totalIdle() + asset.balanceOf(address(A_TOKEN));
    }

    /// NEEDED TO BE OVERRIDDEN BY STRATEGIST

    /// @dev Should deploy up to '_amount' of 'asset' in the yield source.
    /// This function is called at the end of a {deposit} or {mint}
    ///     call. Meaning that unless a whitelist is implemented it will
    ///     be entirely permissionless and thus can be sandwiched or otherwise
    ///     manipulated.
    /// @param _amount The amount of 'asset' that the strategy should attempt
    ///     to deposit in the yield source.
    function _deployFunds(uint256 _amount) internal override {
        LENDING_POOL.supply(address(asset), _amount, address(this), 0);
    }

    /// @dev Will attempt to free the '_amount' of 'asset'.
    /// The amount of 'asset' that is already loose has already
    ///     been accounted for.
    ///
    /// This function is called during {withdraw} and {redeem} calls.
    ///     Meaning that unless a whitelist is implemented it will be
    ///     entirely permissionless and thus can be sandwiched or otherwise
    ///     manipulated.
    ///
    /// Should not rely on asset.balanceOf(address(this)) calls other than
    ///     for diff accounting purposes.
    ///
    /// Any difference between `_amount` and what is actually freed will be
    ///     counted as a loss and passed on to the withdrawer. This means
    ///     care should be taken in times of illiquidity. It may be better to revert
    ///     if withdraws are simply illiquid so not to realize incorrect losses.
    /// @param _amount, The amount of 'asset' to be freed.
    function _freeFunds(uint256 _amount) internal override {
        /// We don't check available liquidity because we need the tx to
        /// revert if there is not enough liquidity so we don't improperly
        /// pass a loss on to the user withdrawing.
        LENDING_POOL.withdraw(
            address(asset),
            Math.min(A_TOKEN.balanceOf(address(this)), _amount),
            address(this)
        );
    }

    /// @dev Internal function to harvest all rewards, redeploy any idle
    ///     funds and return an accurate accounting of all funds currently
    ///     held by the Strategy.
    ///
    /// This should do any needed harvesting, rewards selling, accrual,
    ///     redepositing etc. to get the most accurate view of current assets.
    /// NOTE: All applicable assets including loose assets should be
    ///     accounted for in this function.
    ///
    /// Care should be taken when relying on oracles or swap values rather
    ///     than actual amounts as all Strategy profit/loss accounting will
    ///     be done based on this returned value.
    ///
    /// This can still be called post a shutdown, a strategist can check
    ///     `TokenizedStrategy.isShutdown()` to decide if funds should be
    ///     redeployed or simply realize any profits/losses.
    /// @return _totalAssets A trusted and accurate account for the total
    ///     amount of 'asset' the strategy currently holds including idle funds.
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        if (claimRewards) {
            // Claim and sell any rewards to `asset`.
            _claimAndSellRewards();
        }

        if (!TokenizedStrategy.isShutdown()) {
            // deposit any loose funds
            uint256 looseAsset = asset.balanceOf(address(this));
            if (looseAsset > 0) {
                LENDING_POOL.supply(
                    address(asset),
                    Math.min(looseAsset, availableDepositLimit(address(this))),
                    address(this),
                    0
                );
            }
        }

        _totalAssets =
            A_TOKEN.balanceOf(address(this)) +
            asset.balanceOf(address(this));
    }

    /// @notice Used to claim any pending rewards and sell them to asset.
    function _claimAndSellRewards() internal {
        //claim all rewards
        address[] memory assets = new address[](1);
        assets[0] = address(A_TOKEN);
        (address[] memory rewardsList, ) = rewardsController
            .claimAllRewardsToSelf(assets);
        //swap as much as possible back to want
        address token;

        for (uint256 i = 0; i < rewardsList.length; ++i) {
            token = rewardsList[i];
            if (token == address(asset)) {
                continue;
            } else {
                uint256 balance = ERC20(token).balanceOf(address(this));

                if (balance > minAmountToSellMapping[token]) {
                    _swapFrom(token, address(asset), balance, 0);
                }
            }
        }
    }

    /// @dev Optional function for a strategist to override that will
    ///     allow management to manually withdraw deployed funds from the
    ///     yield source if a strategy is shutdown.
    /// This should attempt to free `_amount`, noting that `_amount` may
    ///     be more than is currently deployed.
    ///
    /// NOTE: This will not realize any profits or losses. A separate
    ///     {report} will be needed in order to record any profit/loss. If
    ///     a report may need to be called after a shutdown it is important
    ///     to check if the strategy is shutdown during {_harvestAndReport}
    ///     so that it does not simply re-deploy all funds that had been freed.
    /// EX:
    ///     if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
    ///         depositFunds...
    ///     }
    /// @param _amount The amount of asset to attempt to free.
    function _emergencyWithdraw(uint256 _amount) internal override {
        LENDING_POOL.withdraw(
            address(asset),
            Math.min(_amount, A_TOKEN.balanceOf(address(this))),
            address(this)
        );
    }
}
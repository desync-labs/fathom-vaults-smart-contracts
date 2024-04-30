// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023
pragma solidity 0.8.19;

import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { SafeMath } from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { BaseStrategy } from "./BaseStrategy.sol";
import { IUniversalRouter } from "./interfaces/liquidationStrategy/IUniversalRouter.sol";
import { IPermit2 } from "./interfaces/liquidationStrategy/IPermit2.sol";
import { IFlashLendingCallee } from "./interfaces/liquidationStrategy/IFlashLendingCallee.sol";
import { ILiquidationStrategy } from "./interfaces/liquidationStrategy/ILiquidationStrategy.sol";
import { IERC165 } from "./interfaces/liquidationStrategy/IERC165.sol";
import { IGenericTokenAdapter } from "./interfaces/liquidationStrategy/IGenericTokenAdapter.sol";
import { IUniswapV2Router02 } from "./interfaces/liquidationStrategy/IUniswapV2Router02.sol";
import { IStablecoinAdapter } from "./interfaces/liquidationStrategy/IStablecoinAdapter.sol";
import { IBookKeeper } from "./interfaces/liquidationStrategy/IBookKeeper.sol";
import { BytesHelper } from "./libraries/BytesHelper.sol";

/// @title LiquidationStrategy for FathomVault
/// @notice Enables participation in generating profits from liquidations and contributes to the liquidation of FXD positions.
/// @dev Inherits from BaseStrategy, ReentrancyGuard, implements IFlashLendingCallee, and IERC165.

// solhint-disable
contract LiquidationStrategy is BaseStrategy, ReentrancyGuard, IFlashLendingCallee, ILiquidationStrategy, IERC165 {
    using SafeERC20 for ERC20;
    using SafeMath for uint256;
    using BytesHelper for *;

    struct LocalVars {
        address liquidatorAddress;
        IGenericTokenAdapter tokenAdapter;
        address routerV2;
        address routerV3;
        uint256 v2Ratio; // bps 10000 = 1%
    }

    struct CollateralInfo {
        uint256 CollateralAmount;
        uint256 amountNeededToPayDebt;
        uint256 averagePriceOfCollateral;
    }

    struct UniswapV3Info {
        address permit2;
        address universalRouter;
        uint24 poolFee;
    }

    // Command for V3_SWAP_EXACT_IN
    bytes1 constant COMMAND = 0x00; // Assuming 0x00 is the COMMAND for V3_SWAP_EXACT_IN

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;

    IStablecoinAdapter public stablecoinAdapter;
    IBookKeeper public bookKeeper;
    address public strategyManager;
    address public fixedSpreadLiquidationStrategy;
    ERC20 public fathomStablecoin;
    ERC20 public usdToken;

    mapping(address => CollateralInfo) public idleCollateral;
    mapping(address => UniswapV3Info) public uniswapV3Info;

    event LogSetStrategyManager(address _strategyManager);
    event LogSetFixedSpreadLiquidationStrategy(address _fixedSpreadLiquidationStrategy);
    event LogShutdownWithdrawCollateral(address _strategyManager, uint256 _amount);
    event LogSellCollateralV2(
        address[] _path,
        IUniswapV2Router02 _router,
        uint256 _collateralAmount,
        uint256 _minAmountOut,
        uint256 _dexAmountOut,
        uint256 _receivedAmount
    );
    event LogSellCollateralV3(address _universalRouter, uint256 _collateralAmount, uint256 _receivedAmount);
    event LogFlashLiquidationSuccess(
        address indexed liquidatorAddress,
        uint256 indexed debtValueToRepay,
        uint256 indexed collateralAmountToLiquidate,
        uint256 fathomStablecoinReceivedV2,
        uint256 fathomStablecoinReceivedV3,
        uint256 V2RatioBPS
    );
    event LogSetBookKeeper(address _bookKeeper);

    event LogSetV3Info(address _permit2, address _routerV3);
    event LogProfitOrLoss(uint256 _amount, bool _isProfit);
    event LogSetUSDTInPath(address _usdToken);

    error ZeroAddress();
    error SameStrategyManager();
    error SameBookKeeper();
    error SameFixedSpreadLiquidationStrategy();
    error NotStrategyManager();
    error NotFixedSpreadLiquidationStrategy();
    error ZeroAmount();
    error WrongAmount();
    error DEXCannotGiveEnoughAmount();
    error NotEnoughToRepayDebt();
    error V3InfoNotSet();
    error SameV3Info();
    error HighChanceOfLoss();

    modifier onlyStrategyManager() {
        if (msg.sender != strategyManager) revert NotStrategyManager();
        _;
    }

    modifier onlyFixedSpreadLiquidationStrategy() {
        if (msg.sender != fixedSpreadLiquidationStrategy) revert NotFixedSpreadLiquidationStrategy();
        _;
    }

    constructor(
        address _asset,
        string memory _name,
        address _tokenizedStrategyAddress,
        address _strategyManager,
        address _fixedSpreadLiquidationStrategy,
        address _bookKeeper,
        address _stablecoinAdapter
    ) BaseStrategy(_asset, _name, _tokenizedStrategyAddress) {
        if (_asset == address(0)) revert ZeroAddress();
        if (_tokenizedStrategyAddress == address(0)) revert ZeroAddress();
        if (_strategyManager == address(0)) revert ZeroAddress();
        if (_fixedSpreadLiquidationStrategy == address(0)) revert ZeroAddress();
        if (_bookKeeper == address(0)) revert ZeroAddress();
        if (_stablecoinAdapter == address(0)) revert ZeroAddress();
        strategyManager = _strategyManager;
        fixedSpreadLiquidationStrategy = _fixedSpreadLiquidationStrategy;
        bookKeeper = IBookKeeper(_bookKeeper);
        stablecoinAdapter = IStablecoinAdapter(_stablecoinAdapter);
        fathomStablecoin = ERC20(_asset);
    }

    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        // Return the remaining room.
        return type(uint256).max - asset.balanceOf(address(this));
    }

    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        return TokenizedStrategy.totalIdle();
    }

    /// @notice Sets the strategy manager address.
    /// @dev Only the current strategy manager can call this function.
    /// @param _strategyManager The address of the new strategy manager.
    function setStrategyManager(address _strategyManager) external onlyStrategyManager {
        if (_strategyManager == address(0)) revert ZeroAddress();
        if (_strategyManager == strategyManager) revert SameStrategyManager();
        strategyManager = _strategyManager;
        emit LogSetStrategyManager(_strategyManager);
    }

    /// @notice Sets the FixedSpreadLiquidationStrategy contract address.
    /// @dev Only the current strategy manager can call this function.
    /// This is critical as it determines who can initiate the flashLendingCall.
    /// @param _fixedSpreadLiquidationStrategy The address of the new FixedSpreadLiquidationStrategy contract.
    function setFixedSpreadLiquidationStrategy(address _fixedSpreadLiquidationStrategy) external onlyStrategyManager {
        if (_fixedSpreadLiquidationStrategy == address(0)) revert ZeroAddress();
        if (_fixedSpreadLiquidationStrategy == fixedSpreadLiquidationStrategy) revert SameFixedSpreadLiquidationStrategy();
        fixedSpreadLiquidationStrategy = _fixedSpreadLiquidationStrategy;
        emit LogSetFixedSpreadLiquidationStrategy(_fixedSpreadLiquidationStrategy);
    }

    /// @notice Sets the BookKeeper contract address.
    /// @dev Only the current strategy manager can call this function.
    /// @param _bookKeeper The address of the new BookKeeper contract.
    function setBookKeeper(address _bookKeeper) external onlyStrategyManager {
        if (_bookKeeper == address(0)) revert ZeroAddress();
        if (_bookKeeper == address(bookKeeper)) revert SameBookKeeper();
        bookKeeper = IBookKeeper(_bookKeeper);
        emit LogSetBookKeeper(_bookKeeper);
    }

    /// @notice Sets the UniswapV3 permit2 and UniversalRouter contract addresses.
    /// @dev Only the current strategy manager can call this function.
    /// @param _permit2 The address of the UniswapV3 permit2 contract.
    /// @param _universalRouter The address of the UniswapV3 UniversalRouter contract.
    function setV3Info(address _permit2, address _universalRouter, uint24 _poolFee) external onlyStrategyManager {
        if (_permit2 == address(0) || _universalRouter == address(0)) revert ZeroAddress();
        if (_poolFee == 0) revert ZeroAmount();
        if (uniswapV3Info[_universalRouter].permit2 == _permit2 && uniswapV3Info[_universalRouter].universalRouter == _universalRouter && uniswapV3Info[_universalRouter].poolFee == _poolFee) revert SameV3Info();
        uniswapV3Info[_universalRouter] = UniswapV3Info({ permit2: _permit2, universalRouter: _universalRouter, poolFee: _poolFee });
        emit LogSetV3Info(_permit2, _universalRouter);
    }

    function setUSDTInPath(address _usdToken) external onlyStrategyManager {
        if (_usdToken == address(0)) revert ZeroAddress();
        usdToken = ERC20(_usdToken);
        emit LogSetUSDTInPath(_usdToken);
    }

    /// @notice Allows the strategy manager to sell Collateral, held by the contract, to UniV2.
    /// @dev Only the current strategy manager can call this function.
    /// This allows for managing the Collateral obtained through liquidations.
    /// @param _router The UniswapV2Router02 (or a fork) used for the sale.
    /// @param _amount The amount of Collateral to sell.
    /// @param _minAmountOut The minimum amount of FXD to accept for the sale.
    function sellCollateralV2(address _collateral, IUniswapV2Router02 _router, uint256 _amount, uint256 _minAmountOut) external onlyStrategyManager {
        if (address(_router) == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();
        if (_amount > idleCollateral[_collateral].CollateralAmount) revert WrongAmount();

        // Calculate the cost of Collateral in terms of FXD using the average price
        uint256 costOfCollateralInFXD = _amount.mul(idleCollateral[_collateral].averagePriceOfCollateral).div(WAD); 
        uint256 balanceOfFXDBeforeSwap = fathomStablecoin.balanceOf(address(this));
        
        // Existing logic for selling Collateral
        idleCollateral[_collateral].CollateralAmount -= _amount;

        _nullifyIdleCollateral(_collateral);

        _adjustAmountNeededToPayDebt(_collateral, _amount.mul(idleCollateral[_collateral].averagePriceOfCollateral).div(WAD));

        (address[] memory path, uint256 dexAmountOut) = _computeMostProfitablePath(_router, _collateral, _amount);

        if (_minAmountOut > dexAmountOut) revert DEXCannotGiveEnoughAmount();

        uint256 receivedAmount = _sellCollateralV2(_collateral, path, _router, _amount, _minAmountOut);
        
        emit LogSellCollateralV2(path, _router, _amount, _minAmountOut, dexAmountOut, receivedAmount);

        uint256 balanceOfFXDAfterSwap = fathomStablecoin.balanceOf(address(this));
        uint256 fxdReceived = balanceOfFXDAfterSwap.sub(balanceOfFXDBeforeSwap); // FXD gained from the swap

        _handleLogicForProfitOrLoss(fxdReceived, costOfCollateralInFXD);
    }


    /// @notice Allows the strategy manager to sell Collateral, held by the contract, to UniV3.
    /// @dev Only the current strategy manager can call this function.
    /// This function will work only when the UniversalRouter and Permit2 contracts addresses are already set in uniswapV3Info.
    /// This allows for managing the Collateral obtained through liquidations.
    /// @param _universalRouter The UniswapV3(or a fork)'s UniversalRouter  used for the sale.
    /// @param _amount The amount of Collateral to sell.

    function sellCollateralV3(address _collateral, address _universalRouter, uint256 _amount) external onlyStrategyManager {
        if (_universalRouter == address(0)) revert ZeroAddress();
        if (_amount == 0) revert ZeroAmount();
        if (_amount > idleCollateral[_collateral].CollateralAmount) revert WrongAmount();
        if (uniswapV3Info[_universalRouter].universalRouter == address(0) || 
            uniswapV3Info[_universalRouter].permit2 == address(0) || 
            uniswapV3Info[_universalRouter].poolFee == 0) revert V3InfoNotSet();

        // Calculate the cost of Collateral in terms of FXD using the average price
        uint256 costOfCollateralInFXD = _amount.mul(idleCollateral[_collateral].averagePriceOfCollateral).div(WAD); 
        uint256 balanceOfFXDBeforeSwap = fathomStablecoin.balanceOf(address(this));
        
        // Existing logic for selling Collateral
        idleCollateral[_collateral].CollateralAmount -= _amount;

        _nullifyIdleCollateral(_collateral);

        _adjustAmountNeededToPayDebt(_collateral, _amount.mul(idleCollateral[_collateral].averagePriceOfCollateral).div(WAD));

        uint256 receivedAmount = _sellCollateralV3(_collateral, address(fathomStablecoin), _amount, 3000, _universalRouter);
        emit LogSellCollateralV3(_universalRouter, _amount, receivedAmount); // This line is crucial for logging the sale details

        uint256 balanceOfFXDAfterSwap = fathomStablecoin.balanceOf(address(this));
        uint256 fxdReceived = balanceOfFXDAfterSwap.sub(balanceOfFXDBeforeSwap); // FXD gained from the swap
        
        _handleLogicForProfitOrLoss(fxdReceived, costOfCollateralInFXD);
    }


    /// @notice Withdraws a specified amount of Collateral from the contract.
    /// @dev Only the current strategy manager can call this function.
    /// Useful for managing the reserves after liquidation events.
    /// @param _amount The amount of Collateral to withdraw.
    function shutdownWithdrawCollateral(address _collateral, uint256 _amount) external onlyStrategyManager {
        if (_amount == 0) revert ZeroAmount();
        if (_amount > idleCollateral[_collateral].CollateralAmount) revert WrongAmount();

        idleCollateral[_collateral].CollateralAmount = idleCollateral[_collateral].CollateralAmount - _amount;

        _nullifyIdleCollateral(_collateral);

        _adjustAmountNeededToPayDebt(_collateral, _amount.mul(idleCollateral[_collateral].averagePriceOfCollateral).div(WAD));

        ERC20(_collateral).safeTransfer(strategyManager, _amount);
        emit LogShutdownWithdrawCollateral(strategyManager, _amount);
    }

    /// @notice Withdraws a specified amount of the strategy's asset (FXD) in the case of an emergency.
    /// @dev Only the current strategy manager can call this function.
    /// This is part of the emergency shutdown mechanism.
    /// @param _amount The amount of FXD to withdraw.
    function shutdownWithdraw(uint256 _amount) external override onlyStrategyManager {
        _emergencyWithdraw(_amount);
    }

    /// @notice Handles the liquidation process, swapping Collateral for FXD, and repaying debt.
    /// @dev Can only be called by the FixedSpreadLiquidationStrategy contract.
    /// This function is critical for the flash liquidation process.
    /// @param _debtValueToRepay The value of the debt to repay in the liquidation process, in RAY.
    /// @param _collateralAmountToLiquidate The amount of collateral to liquidate, in WAD.
    /// @param data Encoded data containing liquidatorAddress, tokenAdapter, and router information.
    function flashLendingCall(
        address,
        uint256 _debtValueToRepay, // [rad]
        uint256 _collateralAmountToLiquidate, // [wad]
        bytes calldata data
    ) external onlyFixedSpreadLiquidationStrategy nonReentrant {
        LocalVars memory _vars;
        (_vars.liquidatorAddress, _vars.tokenAdapter, _vars.routerV2, _vars.routerV3, _vars.v2Ratio) = abi.decode(
            data,
            (address, IGenericTokenAdapter, address, address, uint256)
        );
        // Retrieve collateral token from CollateralTokenAdapter
        uint256 retrievedCollateralAmount = _retrieveCollateral(_vars.tokenAdapter.collateralToken(), _vars.tokenAdapter, _collateralAmountToLiquidate);
        // +1 to compensate for precision loss with division
        uint256 amountNeededToPayDebt = _debtValueToRepay.div(RAY) + 1;
        uint256 fathomStablecoinReceivedV2;
        uint256 fathomStablecoinReceivedV3;
        if (uniswapV3Info[_vars.routerV3].universalRouter == address(0) && _vars.routerV2 != address(0)) {
            _vars.v2Ratio = 10000; // Adjust to use V2 fully
        }
        // If bot tells the strategy to not use DEX
        if (_vars.routerV2 == address(0) && _vars.routerV3 == address(0)) {
            if (fathomStablecoin.balanceOf(address(this)) < amountNeededToPayDebt) {
                revert NotEnoughToRepayDebt();
            }
            _depositStablecoin(amountNeededToPayDebt, _vars.liquidatorAddress);
            idleCollateral[_vars.tokenAdapter.collateralToken()].CollateralAmount += retrievedCollateralAmount;
            idleCollateral[_vars.tokenAdapter.collateralToken()].amountNeededToPayDebt += amountNeededToPayDebt;
            idleCollateral[_vars.tokenAdapter.collateralToken()].averagePriceOfCollateral = idleCollateral[_vars.tokenAdapter.collateralToken()].amountNeededToPayDebt.mul(WAD).div(idleCollateral[_vars.tokenAdapter.collateralToken()].CollateralAmount);
            emit LogFlashLiquidationSuccess(
                _vars.liquidatorAddress,
                amountNeededToPayDebt,
                _collateralAmountToLiquidate,
                fathomStablecoinReceivedV2,
                fathomStablecoinReceivedV3,
                _vars.v2Ratio
            );
        } else {
            uint256 _collateralAmountToLiquidateV2 = _vars.v2Ratio == 0 ? 0 : _collateralAmountToLiquidate.mul(_vars.v2Ratio).div(10000);
            uint256 balanceOfFXDBeforeSwap = fathomStablecoin.balanceOf(address(this));
            if (_vars.v2Ratio > 0) {
                fathomStablecoinReceivedV2 = _handleCollateralSellingV2(
                    _vars,
                    _collateralAmountToLiquidateV2,
                    amountNeededToPayDebt.mul(_vars.v2Ratio).div(10000)
                );
            }
            if (_vars.v2Ratio < 10000) {
                fathomStablecoinReceivedV3 = _sellCollateralV3(
                    _vars.tokenAdapter.collateralToken(),
                    address(fathomStablecoin),
                    _collateralAmountToLiquidate.sub(_collateralAmountToLiquidateV2),
                    uniswapV3Info[_vars.routerV3].poolFee,
                    uniswapV3Info[_vars.routerV3].universalRouter
                );
            }
            if ((fathomStablecoinReceivedV2 + fathomStablecoinReceivedV3) < amountNeededToPayDebt) {
                if (fathomStablecoin.balanceOf(address(this)) < amountNeededToPayDebt) {
                    revert NotEnoughToRepayDebt();
                }
            }
            _depositStablecoin(amountNeededToPayDebt, _vars.liquidatorAddress);
            uint256 balanceOfFXDAfterSwap = fathomStablecoin.balanceOf(address(this));
            emit LogFlashLiquidationSuccess(
                _vars.liquidatorAddress,
                amountNeededToPayDebt,
                _collateralAmountToLiquidate,
                fathomStablecoinReceivedV2,
                fathomStablecoinReceivedV3,
                _vars.v2Ratio
            );
            if (balanceOfFXDBeforeSwap > balanceOfFXDAfterSwap) {
                emit LogProfitOrLoss(balanceOfFXDBeforeSwap - balanceOfFXDAfterSwap, true);
            } else {
                emit LogProfitOrLoss(balanceOfFXDAfterSwap - balanceOfFXDBeforeSwap, false);
            }
        }
    }

    function supportsInterface(bytes4 _interfaceId) external pure returns (bool) {
        return type(IFlashLendingCallee).interfaceId == _interfaceId;
    }

    function _nullifyIdleCollateral(address _collateral) internal {
        if (idleCollateral[_collateral].CollateralAmount == 0) {
            idleCollateral[_collateral].amountNeededToPayDebt = 0;
            idleCollateral[_collateral].averagePriceOfCollateral = 0;
        }
    }

    function _adjustAmountNeededToPayDebt(address _collateral, uint256 _amount) internal {
        if (idleCollateral[_collateral].amountNeededToPayDebt >= _amount) {
            idleCollateral[_collateral].amountNeededToPayDebt -= _amount;
        } else {
            idleCollateral[_collateral].amountNeededToPayDebt = 0;
        }
    }

    function _handleLogicForProfitOrLoss(uint256 _fxdReceived, uint256 _costOfCollateralInFXD) internal {
        if (_fxdReceived < _costOfCollateralInFXD) {
            emit LogProfitOrLoss(_costOfCollateralInFXD - _fxdReceived, false); // Indicates a loss
        } else {
            emit LogProfitOrLoss(_fxdReceived - _costOfCollateralInFXD, true); // Indicates a profit
        }
    }

    function _emergencyWithdraw(uint256 _amount) internal override {
        if (_amount == 0) revert ZeroAmount();
        if (_amount > asset.balanceOf(address(this))) revert WrongAmount();
        asset.safeTransfer(strategyManager, _amount);
    }

    function _depositStablecoin(uint256 _amount, address _liquidatorAddress) internal {
        fathomStablecoin.safeApprove(address(stablecoinAdapter), type(uint).max);
        stablecoinAdapter.deposit(_liquidatorAddress, _amount, abi.encode(0));
        fathomStablecoin.safeApprove(address(stablecoinAdapter), 0);
    }

    function _retrieveCollateral(address _collateral, IGenericTokenAdapter _tokenAdapter, uint256 _amount) internal returns (uint256) {
        bookKeeper.whitelist(address(_tokenAdapter));
        uint256 balanceBefore = ERC20(_collateral).balanceOf(address(this));
        _tokenAdapter.withdraw(address(this), _amount, abi.encode(0));
        uint256 balanceAfter = ERC20(_collateral).balanceOf(address(this));
        return balanceAfter.sub(balanceBefore);
    }

    function _handleCollateralSellingV2(
        LocalVars memory _vars,
        uint256 _collateralAmountToLiquidateV2,
        uint256 amountNeededToPayDebtV2
    ) internal returns (uint256 fathomStablecoinReceivedV2) {
        (address[] memory path, uint256 dexAmountOut) = _computeMostProfitablePath(
            IUniswapV2Router02(_vars.routerV2),
            _vars.tokenAdapter.collateralToken(),
            _collateralAmountToLiquidateV2
        );
        uint256 minAmountOutAfterComparison = dexAmountOut < amountNeededToPayDebtV2 ? dexAmountOut : amountNeededToPayDebtV2;
        return
            _sellCollateralV2(
                _vars.tokenAdapter.collateralToken(),
                path,
                IUniswapV2Router02(_vars.routerV2),
                _collateralAmountToLiquidateV2,
                minAmountOutAfterComparison
            );
    }

    function _sellCollateralV2(
        address _token,
        address[] memory _path,
        IUniswapV2Router02 _router,
        uint256 _amount,
        uint256 _minAmountOut
    ) internal returns (uint256 receivedAmount) {
            address _tokencoinAddress = _path[_path.length - 1];
            uint256 _tokencoinBalanceBefore = ERC20(_tokencoinAddress).balanceOf(address(this));

            // Check if enough FXD will be returned from the DEX to complete flash liquidation
            uint256[] memory amounts = _router.getAmountsOut(_amount, _path);
            uint256 amountToReceive = amounts[amounts.length - 1];

            if (amountToReceive < _minAmountOut) {
                revert(
                    string(
                        abi.encodePacked(
                            " collateralReceived : ",
                            string(ERC20(_token).balanceOf(address(this))._uintToASCIIBytes()),
                            " collaterallToSell : ",
                            string(_amount._uintToASCIIBytes()),
                            " amountNeeded : ",
                            string((_minAmountOut)._uintToASCIIBytes()),
                            " actualAmountReceived : ",
                            string(amountToReceive._uintToASCIIBytes()),
                            " output token : ",
                            string(_path[_path.length - 1]._addressToASCIIBytes())
                        )
                    )
                );
            }
            ERC20(_token).safeApprove(address(_router), type(uint).max);
            _router.swapExactTokensForTokens(
                _amount, // col
                _minAmountOut, // fxd
                _path,
                address(this),
                block.timestamp + 1000
            );
            ERC20(_token).safeApprove(address(_router), 0);

            uint256 _tokencoinBalanceAfter = ERC20(_tokencoinAddress).balanceOf(address(this));

            receivedAmount = _tokencoinBalanceAfter.sub(_tokencoinBalanceBefore);
    }

    function _sellCollateralV3(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint24 _poolFee,
        address _routerV3
    ) internal returns (uint256 receivedAmount) {
        uint256 _tokencoinBalanceBefore = ERC20(_tokenOut).balanceOf(address(this));

        (bytes memory commands, bytes[] memory inputs) = _encodeSwapExactInputSingle(
            address(this),
            _amountIn,
            0,
            abi.encodePacked(_tokenIn, _poolFee, _tokenOut),
            true
        );

        ERC20(_tokenIn).safeApprove(uniswapV3Info[_routerV3].permit2, _amountIn);

        IPermit2(uniswapV3Info[_routerV3].permit2).approve(
            _tokenIn,
            address(uniswapV3Info[_routerV3].universalRouter),
            uint160(_amountIn),
            uint48(block.timestamp)
        );

        IUniversalRouter(uniswapV3Info[_routerV3].universalRouter).execute(commands, inputs, block.timestamp);

        ERC20(_tokenIn).safeApprove(uniswapV3Info[_routerV3].permit2, 0);

        uint256 _tokencoinBalanceAfter = ERC20(_tokenOut).balanceOf(address(this));

        receivedAmount = _tokencoinBalanceAfter.sub(_tokencoinBalanceBefore);

        return receivedAmount;
    }

    // @dev _computeMostProfitablePath should be upgraded/updated once curvePool launches and DEX pool of USDT/FXD will be drained.
    // an alternative solution can be to involvement of Xswap(UniswapV3)
    function _computeMostProfitablePath(
        IUniswapV2Router02 _router,
        address _collateralToken,
        uint256 _collateralAmountToLiquidate
    ) internal view returns (address[] memory, uint256) {
        // DEX (Collateral -> FXD)
        address[] memory path1 = new address[](2);
        path1[0] = _collateralToken;
        path1[1] = address(fathomStablecoin);
        uint256 scenarioOneAmountOut = _getDexAmountOut(_collateralAmountToLiquidate, path1, _router);

        //if USDT is not set in path, then return path1
        if (address(usdToken) == address(0)) {
            return (path1, scenarioOneAmountOut);
        } else {
            // DEX (Collateral -> USDT) -> DEX (USDT -> FXD)
            address[] memory path2 = new address[](3);
            path2[0] = _collateralToken;
            path2[1] = address(usdToken);
            path2[2] = address(fathomStablecoin);
            uint256 scenarioTwoAmountOut = _getDexAmountOut(_collateralAmountToLiquidate, path2, _router);

            if (scenarioOneAmountOut >= scenarioTwoAmountOut) {
                // DEX (Collateral -> FXD)
                return (path1, scenarioOneAmountOut);
            } else {
                // DEX (Collateral -> USDT) -> DEX (USDT -> FXD)
                return (path2, scenarioTwoAmountOut);
            }
        }
    }

    function _getDexAmountOut(
        uint256 _collateralAmountToLiquidate,
        address[] memory _path,
        IUniswapV2Router02 _router
    ) internal view returns (uint256) {
        uint256[] memory amounts = _router.getAmountsOut(_collateralAmountToLiquidate, _path);
        uint256 amountToReceive = amounts[amounts.length - 1];
        return amountToReceive;
    }

    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        _totalAssets = asset.balanceOf(address(this));
    }

    function _encodeSwapExactInputSingle(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        bytes memory path,
        bool sourceOfFundsIsMsgSender
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        // Encode the inputs for the V3_SWAP_EXACT_IN COMMAND
        bytes memory input = abi.encode(recipient, amountIn, amountOutMinimum, path, sourceOfFundsIsMsgSender);

        // Prepare the COMMAND and input for the caller to use with `execute` function of UniversalRouter
        commands = abi.encodePacked(COMMAND);
        inputs = new bytes[](1);
        inputs[0] = input;
    }

    function _deployFunds(uint256 _amount) internal pure override {}

    function _freeFunds(uint256 _amount) internal pure override {}
}

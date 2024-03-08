// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023
pragma solidity 0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./BaseStrategy.sol";
import "./interfaces/liquidationStrategy/IUniversalRouter.sol";
import "./interfaces/liquidationStrategy/IPermit2.sol";
import "./interfaces/liquidationStrategy/IFlashLendingCallee.sol";
import "./interfaces/liquidationStrategy/IERC165.sol";
import "./interfaces/liquidationStrategy/IGenericTokenAdapter.sol";
import {IUniswapV2Router02} from "./interfaces/liquidationStrategy/IUniswapV2Router02.sol";
import "./interfaces/liquidationStrategy/IStablecoinAdapter.sol";
import { IBookKeeper } from "./interfaces/liquidationStrategy/IBookKeeper.sol";
import "./libraries/BytesHelper.sol";

/// @title LiquidationStrategy for FathomVault
/// @notice Enables participation in generating profits from liquidations and contributes to the liquidation of FXD positions.
/// @dev Inherits from BaseStrategy, ReentrancyGuard, implements IFlashLendingCallee, and IERC165.

// solhint-disable
contract LiquidationStrategy is BaseStrategy, ReentrancyGuard, IFlashLendingCallee, IERC165 {
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

    struct WXDCInfo {
        uint256 WXDCAmount;
        uint256 amountNeededToPayDebt;
        uint256 averagePriceOfWXDC;
    }

    struct UniswapV3Info {
        address permit2;
        address universalRouter;
        uint24 poolFee;
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;

    IStablecoinAdapter public stablecoinAdapter;
    IBookKeeper public bookKeeper;
    address public strategyManager;
    address public fixedSpreadLiquidationStrategy;
    ERC20 public WXDC;
    ERC20 public fathomStablecoin;
    ERC20 public usdToken;
    bool public allowLoss = true;
    WXDCInfo public idleWXDC;

    mapping(address => UniswapV3Info) public uniswapV3Info;

    event LogSetStrategyManager(address indexed _strategyManager);
    event LogSetFixedSpreadLiquidationStrategy(address indexed _fixedSpreadLiquidationStrategy);
    event LogShutdownWithdrawWXDC(address indexed _strategyManager, uint256 _amount);
    event LogAllowLoss(bool _allowLoss);
    event LogSellWXDC(
        address[] _path,
        IUniswapV2Router02 _router,
        uint256 _amount,
        uint256 _minAmountOut,
        uint256 _dexAmountOut,
        uint256 _receivedAmount
    );
    event LogFlashLiquidationSuccess(
        address indexed liquidatorAddress,
        uint256 indexed debtValueToRepay,
        uint256 indexed collateralAmountToLiquidate,
        uint256 fathomStablecoinReceivedV2,
        uint256 fathomStablecoinReceivedV3
    );
    event LogSetBookKeeper(address _bookKeeper);

    event LogSetV3Info(address _factory, address _routerV3, address _WXDC, address _poolAddress, address _permit2);

    modifier onlyStrategyManager() {
        require(msg.sender == strategyManager, "LiquidationStrategy: only strategy manager");
        _;
    }

    modifier onlyFixedSpreadLiquidationStrategy() {
        require(msg.sender == fixedSpreadLiquidationStrategy, "LiquidationStrategy: only fixed spread liquidation strategy");
        _;
    }

    constructor(
        address _asset,
        string memory _name,
        address _tokenizedStrategyAddress,
        address _strategyManager,
        address _fixedSpreadLiquidationStrategy,
        address _wrappedXDC,
        address _bookKeeper,
        address _usdToken,
        address _stablecoinAdapter
    ) BaseStrategy(_asset, _name, _tokenizedStrategyAddress) {
        require(_strategyManager != address(0), "LiquidationStrategy: zero address");
        require(_fixedSpreadLiquidationStrategy != address(0), "LiquidationStrategy: zero address");
        require(_wrappedXDC != address(0), "LiquidationStrategy: zero address");
        require(_bookKeeper != address(0), "LiquidationStrategy: zero address");
        require(_usdToken != address(0), "LiquidationStrategy: zero address");
        require(_stablecoinAdapter != address(0), "LiquidationStrategy: zero address");
        strategyManager = _strategyManager;
        fixedSpreadLiquidationStrategy = _fixedSpreadLiquidationStrategy;
        WXDC = ERC20(_wrappedXDC);
        bookKeeper = IBookKeeper(_bookKeeper);
        stablecoinAdapter = IStablecoinAdapter(_stablecoinAdapter);
        fathomStablecoin = ERC20(_asset);
        usdToken = ERC20(_usdToken);
    }

    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        _totalAssets = asset.balanceOf(address(this));
    }

    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        // Return the remaining room.
        return type(uint256).max - asset.balanceOf(address(this));
    }

    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        return TokenizedStrategy.totalIdle();
    }

    /// @notice Withdraws a specified amount of the strategy's asset (FXD) in the case of an emergency.
    /// @dev Only the current strategy manager can call this function.
    /// This is part of the emergency shutdown mechanism.
    /// @param _amount The amount of FXD to withdraw.
    function shutdownWithdraw(uint256 _amount) external override onlyStrategyManager {
        _emergencyWithdraw(_amount);
    }

    /// @notice Sets the strategy manager address.
    /// @dev Only the current strategy manager can call this function.
    /// @param _strategyManager The address of the new strategy manager.
    function setStrategyManager(address _strategyManager) external onlyStrategyManager {
        require(_strategyManager != address(0), "LiquidationStrategy: zero address");
        require(_strategyManager != strategyManager, "LiquidationStrategy: same strategy manager");
        strategyManager = _strategyManager;
        emit LogSetStrategyManager(_strategyManager);
    }

    /// @notice Sets the FixedSpreadLiquidationStrategy contract address.
    /// @dev Only the current strategy manager can call this function.
    /// This is critical as it determines who can initiate the flashLendingCall.
    /// @param _fixedSpreadLiquidationStrategy The address of the new FixedSpreadLiquidationStrategy contract.
    function setFixedSpreadLiquidationStrategy(address _fixedSpreadLiquidationStrategy) external onlyStrategyManager {
        require(_fixedSpreadLiquidationStrategy != address(0), "LiquidationStrategy: zero address");
        require(_fixedSpreadLiquidationStrategy != fixedSpreadLiquidationStrategy, "LiquidationStrategy: same fixed spread liquidation strategy");
        fixedSpreadLiquidationStrategy = _fixedSpreadLiquidationStrategy;
        emit LogSetFixedSpreadLiquidationStrategy(_fixedSpreadLiquidationStrategy);
    }

    function setBookKeeper(address _bookKeeper) external onlyStrategyManager {
        require(_bookKeeper != address(0), "LiquidationStrategy: zero address");
        require(_bookKeeper != address(bookKeeper), "LiquidationStrategy: same book keeper");
        bookKeeper = IBookKeeper(_bookKeeper);
        emit LogSetBookKeeper(_bookKeeper);
    }

    function setV3Info(address _factory, address _routerV3, address _WXDC, address _poolAddress, address _permit2) external onlyStrategyManager {
        require(_factory != address(0), "Invalid address");
        require(_routerV3 != address(0), "Invalid address");
        require(_WXDC != address(0), "Invalid address");
        require(_poolAddress != address(0), "Invalid address");
        require(_permit2 != address(0), "Invalid address");

        uniswapV3Info[_routerV3] = UniswapV3Info({ permit2: _permit2, universalRouter: _routerV3, poolFee: 3000 });

        emit LogSetV3Info(_factory, _routerV3, _WXDC, _poolAddress, _permit2);
    }

    /// @notice Allows the strategy manager to toggle the allowance of losses during liquidation.
    /// @dev Only the current strategy manager can call this function.
    /// This affects how the `flashLendingCall` handles insufficient FXD from collateral sales.
    /// @param _allowLoss A boolean indicating whether losses are allowed (true) or not (false).
    function setAllowLoss(bool _allowLoss) external onlyStrategyManager {
        require(_allowLoss != allowLoss, "LiquidationStrategy: same allowLoss");
        allowLoss = _allowLoss;
        emit LogAllowLoss(_allowLoss);
    }

    /// @notice Withdraws a specified amount of WXDC from the contract.
    /// @dev Only the current strategy manager can call this function.
    /// Useful for managing the reserves after liquidation events.
    /// @param _amount The amount of WXDC to withdraw.
    function shutdownWithdrawWXDC(uint256 _amount) external onlyStrategyManager {
        require(_amount > 0, "LiquidationStrategy: zero amount");
        require(_amount <= idleWXDC.WXDCAmount, "LiquidationStrategy: wrong amount");
        idleWXDC.WXDCAmount = idleWXDC.WXDCAmount - _amount;
        if (idleWXDC.WXDCAmount == 0) {
            idleWXDC.amountNeededToPayDebt = 0;
            idleWXDC.averagePriceOfWXDC = 0;
        }

        uint256 deductAmountNeededToPayDebt = _amount.mul(idleWXDC.averagePriceOfWXDC).div(WAD);
        if (idleWXDC.amountNeededToPayDebt >= deductAmountNeededToPayDebt) {
            idleWXDC.amountNeededToPayDebt -= deductAmountNeededToPayDebt;
        } else {
            idleWXDC.amountNeededToPayDebt = 0;
        }

        WXDC.safeTransfer(strategyManager, _amount);
        emit LogShutdownWithdrawWXDC(strategyManager, _amount);
    }

    /// @notice Allows the strategy manager to sell WXDC held by the contract.
    /// @dev Only the current strategy manager can call this function.
    /// This allows for managing the WXDC obtained through liquidations.
    /// @param _router The UniswapV2Router02 (or a fork) used for the sale.
    /// @param _amount The amount of WXDC to sell.
    /// @param _minAmountOut The minimum amount of FXD to accept for the sale.
    function sellWXDC(IUniswapV2Router02 _router, uint256 _amount, uint256 _minAmountOut) external onlyStrategyManager {
        require(address(_router) != address(0), "LiquidationStrategy: zero address");
        require(_amount > 0, "LiquidationStrategy: zero amount");
        require(_amount <= idleWXDC.WXDCAmount, "LiquidationStrategy: wrong amount");

        idleWXDC.WXDCAmount -= _amount;

        if (idleWXDC.WXDCAmount == 0) {
            idleWXDC.amountNeededToPayDebt = 0;
            idleWXDC.averagePriceOfWXDC = 0;
        }

        uint256 deductAmountNeededToPayDebt = _amount.mul(idleWXDC.averagePriceOfWXDC).div(WAD);
        if (idleWXDC.amountNeededToPayDebt >= deductAmountNeededToPayDebt) {
            idleWXDC.amountNeededToPayDebt -= deductAmountNeededToPayDebt;
        } else {
            idleWXDC.amountNeededToPayDebt = 0;
        }

        (address[] memory path, uint256 dexAmountOut) = _computeMostProfitablePath(_router, address(WXDC), _amount);

        require(_minAmountOut <= dexAmountOut, "LiquidationStrategy: DEX can't give enough amount");

        uint256 receivedAmount = _sellCollateral(address(WXDC), path, _router, _amount, _minAmountOut);
        emit LogSellWXDC(path, _router, _amount, _minAmountOut, dexAmountOut, receivedAmount);
    }

    /// @notice Handles the liquidation process, swapping WXDC for FXD, and repaying debt.
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
        // Retrieve collateral token
        uint256 retrievedCollateralAmount = _retrieveCollateral(_vars.tokenAdapter, _collateralAmountToLiquidate);

        uint256 amountNeededToPayDebt = _debtValueToRepay.div(RAY) + 1;

        //dexAmountOut for rough calculation
        (, uint256 dexAmountOut) = _computeMostProfitablePath(IUniswapV2Router02(_vars.routerV2), _vars.tokenAdapter.collateralToken(), _collateralAmountToLiquidate);

        uint256 fathomStablecoinReceivedV2;
        uint256 fathomStablecoinReceivedV3;

        if (allowLoss == false) {
            // Condition #1 if there lower chance of no loss, sell on DEX
            if (dexAmountOut >= amountNeededToPayDebt) {

                uint256 _collateralAmountToLiquidateV2 = _vars.v2Ratio == 0 ? 0 : _collateralAmountToLiquidate.mul(_vars.v2Ratio).div(10000);
                if (_vars.v2Ratio > 0) {
                    fathomStablecoinReceivedV2 = handleCollateralSellingV2(
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
                    require(fathomStablecoin.balanceOf(address(this)) >= amountNeededToPayDebt, "flashLendingCall: not enough to repay debt");
                }
                _depositStablecoin(amountNeededToPayDebt, _vars.liquidatorAddress);
                emit LogFlashLiquidationSuccess(
                    _vars.liquidatorAddress,
                    amountNeededToPayDebt,
                    _collateralAmountToLiquidate,
                    fathomStablecoinReceivedV2,
                    fathomStablecoinReceivedV3
                );
            } else {
                // Condition #2 if there is high chance of loss, don't sell on DEX
                require(fathomStablecoin.balanceOf(address(this)) >= amountNeededToPayDebt, "flashLendingCall: not enough to repay debt");
                _depositStablecoin(amountNeededToPayDebt, _vars.liquidatorAddress);
                idleWXDC.WXDCAmount += retrievedCollateralAmount;
                idleWXDC.amountNeededToPayDebt += amountNeededToPayDebt;
                idleWXDC.averagePriceOfWXDC = idleWXDC.amountNeededToPayDebt.mul(WAD).div(idleWXDC.WXDCAmount);
                emit LogFlashLiquidationSuccess(
                    _vars.liquidatorAddress,
                    amountNeededToPayDebt,
                    _collateralAmountToLiquidate,
                    fathomStablecoinReceivedV2,
                    fathomStablecoinReceivedV3
                );
            }
        } else {
            // Condition #3 loss is allowed, so if there is loss, make this address pay for the loss.
            uint256 _collateralAmountToLiquidateV2 = _vars.v2Ratio == 0 ? 0 : _collateralAmountToLiquidate.mul(_vars.v2Ratio).div(10000);
            if (_vars.v2Ratio > 0) {
                fathomStablecoinReceivedV2 = handleCollateralSellingV2(
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
                require(fathomStablecoin.balanceOf(address(this)) >= amountNeededToPayDebt, "flashLendingCall: not enough to repay debt");
            }
            // Deposit Fathom Stablecoin for liquidatorAddress
            _depositStablecoin(amountNeededToPayDebt, _vars.liquidatorAddress);
            emit LogFlashLiquidationSuccess(
                _vars.liquidatorAddress,
                amountNeededToPayDebt,
                _collateralAmountToLiquidate,
                fathomStablecoinReceivedV2,
                fathomStablecoinReceivedV3
            );
        }
    }

    function _emergencyWithdraw(uint256 _amount) internal override {
        require(_amount > 0, "LiquidationStrategy: zero amount");
        require(_amount <= asset.balanceOf(address(this)), "LiquidationStrategy: wrong amount");
        asset.safeTransfer(strategyManager, _amount);
    }

    function supportsInterface(bytes4 _interfaceId) external pure returns (bool) {
        return type(IFlashLendingCallee).interfaceId == _interfaceId;
    }

    function _depositStablecoin(uint256 _amount, address _liquidatorAddress) internal {
        fathomStablecoin.safeApprove(address(stablecoinAdapter), type(uint).max);
        stablecoinAdapter.deposit(_liquidatorAddress, _amount, abi.encode(0));
        fathomStablecoin.safeApprove(address(stablecoinAdapter), 0);
    }

    function _retrieveCollateral(IGenericTokenAdapter _tokenAdapter, uint256 _amount) internal returns (uint256) {
        bookKeeper.whitelist(address(_tokenAdapter));
        uint256 balanceBefore = WXDC.balanceOf(address(this));
        _tokenAdapter.withdraw(address(this), _amount, abi.encode(0));
        uint256 balanceAfter = WXDC.balanceOf(address(this));
        return balanceAfter.sub(balanceBefore);
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

    function _getDexAmountOut(
        uint256 _collateralAmountToLiquidate,
        address[] memory _path,
        IUniswapV2Router02 _router
    ) internal view returns (uint256) {
        uint256[] memory amounts = _router.getAmountsOut(_collateralAmountToLiquidate, _path);
        uint256 amountToReceive = amounts[amounts.length - 1];
        return amountToReceive;
    }

    function handleCollateralSellingV2(
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
        if (_path.length != 0) {
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
                _amount, // xdc
                _minAmountOut, // fxd
                _path,
                address(this),
                block.timestamp + 1000
            );
            ERC20(_token).safeApprove(address(_router), 0);

            uint256 _tokencoinBalanceAfter = ERC20(_tokencoinAddress).balanceOf(address(this));

            receivedAmount = _tokencoinBalanceAfter.sub(_tokencoinBalanceBefore);
        }
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

    function _sellCollateral(
        address _token,
        address[] memory _path,
        IUniswapV2Router02 _router,
        uint256 _amount,
        uint256 _minAmountOut
    ) internal returns (uint256 receivedAmount) {
        if (_path.length != 0) {
            ERC20 _tokencoinAddress = ERC20(_path[_path.length - 1]);
            uint256 _tokencoinBalanceBefore = _tokencoinAddress.balanceOf(address(this));

            // Check if enough FXD will be returned from the DEX
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
                _amount, // xdc
                _minAmountOut, // fxd
                _path,
                address(this),
                block.timestamp + 1000
            );
            ERC20(_token).safeApprove(address(_router), 0);

            uint256 _tokencoinBalanceAfter = ERC20(_tokencoinAddress).balanceOf(address(this));

            receivedAmount = _tokencoinBalanceAfter.sub(_tokencoinBalanceBefore);
        }
    }

        function _encodeSwapExactInputSingle(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        bytes memory path,
        bool sourceOfFundsIsMsgSender
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        // Command for V3_SWAP_EXACT_IN
        bytes1 command = 0x00; // Assuming 0x00 is the command for V3_SWAP_EXACT_IN

        // Encode the inputs for the V3_SWAP_EXACT_IN command
        bytes memory input = abi.encode(recipient, amountIn, amountOutMinimum, path, sourceOfFundsIsMsgSender);

        // Prepare the command and input for the caller to use with `execute` function of UniversalRouter
        commands = abi.encodePacked(command);
        inputs = new bytes[](1);
        inputs[0] = input;
    }

    function _deployFunds(uint256 _amount) internal pure override {}

    function _freeFunds(uint256 _amount) internal pure override {}
}

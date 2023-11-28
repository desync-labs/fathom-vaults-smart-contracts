// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.16;

import "../VaultStructs.sol";
import {IERC4626} from "./IERC4626.sol";

interface ISharesManager is IERC4626 {
    // solhint-disable max-line-length
    // solhint-disable ordering

    function balanceOf(address addr) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function spendAllowance(address owner, address spender, uint256 amount) external;
    function transfer(address sender, address receiver, uint256 amount) external;
    function transferFrom(address sender, address receiver, uint256 amount) external returns (bool);
    function approve(address owner, address spender, uint256 amount) external returns (bool);
    function increaseAllowance(address owner, address spender, uint256 amount) external returns (bool);
    function decreaseAllowance(address owner, address spender, uint256 amount) external returns (bool);
    function permit(address owner, address spender, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external returns (bool);
    function burnShares(uint256 shares, address owner) external;
    function unlockedShares() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function burnUnlockedShares() external;
    function totalAssets() external view returns (uint256);
    function convertToAssets(uint256 shares, Rounding rounding) external view returns (uint256);
    function convertToShares(uint256 assets, Rounding rounding) external view returns (uint256);
    function erc20SafeApprove(address token, address spender, uint256 amount) external;
    function erc20SafeTransferFrom(address token, address sender, address receiver, uint256 amount) external;
    function erc20SafeTransfer(address token, address receiver, uint256 amount) external;
    function issueShares(uint256 shares, address recipient) external;
    function issueSharesForAmount(uint256 amount, address recipient) external returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function maxWithdraw(address owner, uint256 _maxLoss, address[] memory _strategies) external returns (uint256);
    function deposit(address sender, address recipient, uint256 assets) external returns (uint256);
    function mint(address sender, address recipient, uint256 shares) external returns (uint256);
    function assessShareOfUnrealisedLosses(address strategy, uint256 assetsNeeded) external view returns (uint256);
    function withdrawFromStrategy(address strategy, uint256 assetsToWithdraw) external;
    function calculateShareManagement(uint256 loss, uint256 totalFees, uint256 protocolFees) external returns (ShareManagement memory shareManagement);
    function handleShareBurnsAndIssues(ShareManagement memory shares, FeeAssessment memory fees, uint256 gain, uint256 loss, address strategy) external returns (uint256 , uint256);
    function manageUnlockingOfShares(uint256 previouslyLockedShares, uint256 newlyLockedShares) external;
}
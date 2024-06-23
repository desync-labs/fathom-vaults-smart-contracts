// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright Fathom 2023

pragma solidity 0.8.19;

// 0xE3E22410ea34661F2b7d5c13EDf7b0c069BD4153
interface IFactoryOld {
    function updateVaultPackage(address _vaultPackage) external;

    function updateFeeConfig(address _feeRecipient, uint16 _feeBPS) external;

    function deployVault(
        uint32 _profitMaxUnlockTime, // 604800
        uint256 _assetType, //1 
        address _asset,  // 0xDf29cB40Cb92a1b8E8337F542E3846E185DefF96 // fxd
        string calldata _name, // "FXD-DeFi-1"
        string calldata _symbol, // "fvFXDDefi1" 
        address _accountant, // 0xe732aAd84ed3a55B02FBE7DF10334c4d2a06afBf
        address _admin //0x0Eb7DEE6e18Cce8fE839E986502d95d47dC0ADa3
    ) external returns (address);

    function getVaults() external view returns (address[] memory);

    function getVaultCreator(address _vault) external view returns (address);

    function protocolFeeConfig() external view returns (uint16 /*feeBps*/, address /*feeRecipient*/);

}
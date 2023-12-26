module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const assetAddress = "0xdf29cb40cb92a1b8e8337f542e3846e185deff96"; // FXD Token on Apothem
    const vaultTokenName = "Vault Shares FXD";
    const vaultTokenSymbol = "vFXD";
    const vaultTokenDecimals = 18;
    const assetSymbol = "FXD";
    const assetDecimals = 18;
    const profitMaxUnlockTime = 60; // 1 year in seconds

    const asset = await deploy("Token", {
        from: deployer,
        args: [assetSymbol, assetDecimals],
        log: true,
    });

    const strategy = await deploy("MockTokenizedStrategy", {
        from: deployer,
        args: [asset.address, "Mock Tokenized Strategy", deployer, deployer, profitMaxUnlockTime],
        log: true,
    });

    const vaultPackage = await deploy("VaultPackage", {
        from: deployer,
        args: [],
        log: true,
    });

    await deploy("FathomVault", {
        from: deployer,
        args: [vaultPackage.address, []],
        log: true,
    });
};

module.exports.tags = ["FathomVault"];

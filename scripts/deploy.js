module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const assetAddress = "0xDf29cB40Cb92a1b8E8337F542E3846E185DefF96"; // FXD Token on Apothem
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

    const sharesManager = await deploy("SharesManager", {
        from: deployer,
        args: [asset.address, vaultTokenDecimals, vaultTokenName, vaultTokenSymbol],
        log: true,
    });

    const strategyManager = await deploy("StrategyManager", {
        from: deployer,
        args: [asset.address, sharesManager.address],
        log: true,
    });

    const strategy = await deploy("MockTokenizedStrategy", {
        from: deployer,
        args: [asset.address, "Mock Tokenized Strategy", deployer, deployer, profitMaxUnlockTime],
        log: true,
    });

    const setters = await deploy("Setters", {
        from: deployer,
        args: [sharesManager.address],
        log: true,
    });

    const governance = await deploy("Governance", {
        from: deployer,
        args: [sharesManager.address],
        log: true,
    });

    await deploy("FathomVault", {
        from: deployer,
        args: [profitMaxUnlockTime, strategyManager.address, sharesManager.address, setters.address, governance.address],
        log: true,
    });
};

module.exports.tags = ["FathomVault"];

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

    const sharesManagerPackage = await deploy("SharesManagerPackage", {
        from: deployer,
        args: [],
        log: true,
    });

    const sharesManager = await deploy("SharesManager", {
        from: deployer,
        args: [sharesManagerPackage.address, []],
        log: true,
    });

    const strategyManagerPackage = await deploy("StrategyManagerPackage", {
        from: deployer,
        args: [],
        log: true,
    });

    const strategyManager = await deploy("StrategyManager", {
        from: deployer,
        args: [strategyManagerPackage.address, []],
        log: true,
    });

    const strategy = await deploy("MockTokenizedStrategy", {
        from: deployer,
        args: [asset.address, "Mock Tokenized Strategy", deployer, deployer, profitMaxUnlockTime],
        log: true,
    });

    const settersPackage = await deploy("SettersPackage", {
        from: deployer,
        args: [],
        log: true,
    });

    const setters = await deploy("Setters", {
        from: deployer,
        args: [settersPackage.address, []],
        log: true,
    });

    const governancePackage = await deploy("GovernancePackage", {
        from: deployer,
        args: [],
        log: true,
    });

    const governance = await deploy("Governance", {
        from: deployer,
        args: [governancePackage.address, []],
        log: true,
    });

    await deploy("FathomVault", {
        from: deployer,
        args: [profitMaxUnlockTime, strategyManager.address, sharesManager.address, setters.address, governance.address],
        log: true,
    });
};

module.exports.tags = ["FathomVault"];

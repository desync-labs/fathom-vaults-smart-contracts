module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const assetSymbol = "FXD";
    const assetDecimals = 18;
    const profitMaxUnlockTime = 60; // 1 minute in seconds
    const performanceFee = 100; // 1% of gain

    const asset = await deploy("Token", {
        from: deployer,
        args: [assetSymbol, assetDecimals],
        log: true,
    });

    await deploy("MockTokenizedStrategy", {
        from: deployer,
        args: [asset.address, "Mock Tokenized Strategy", deployer, deployer, profitMaxUnlockTime],
        log: true,
    });

    await deploy("GenericAccountant", {
        from: deployer,
        args: [performanceFee, deployer, deployer],
        log: true,
    });

    await deploy("VaultPackage", {
        from: deployer,
        args: [],
        log: true,
    });

    const factoryPackage = await deploy("FactoryPackage", {
        from: deployer,
        args: [],
        log: true,
    });

    await deploy("Factory", {
        from: deployer,
        args: [factoryPackage.address, deployer, "0x"],
        log: true,
    });
};

module.exports.tags = ["Factory","GenericAccountant","Token","MockTokenizedStrategy"];

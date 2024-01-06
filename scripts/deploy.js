module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();
    const [owner, addr1, addr2] = await ethers.getSigners();

    const assetAddress = "0xdf29cb40cb92a1b8e8337f542e3846e185deff96"; // FXD Token on Apothem
    const recipientAddress = "0x0db96Eb1dc48554bB0f8203A6dE449B2FcCF51a6"
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

    const accountant = await deploy("GenericAccountant", {
        from: deployer,
        args: [],
        log: true,
    });

    const vaultPackage = await deploy("VaultPackage", {
        from: deployer,
        args: [],
        log: true,
    });

    const factoryPackage = await deploy("FactoryPackage", {
        from: deployer,
        args: [],
        log: true,
    });

    const factory = await deploy("Factory", {
        from: deployer,
        args: [factoryPackage.address, "0x"],
        log: true,
    });
};

module.exports.tags = ["Factory","GenericAccountant","Token","MockTokenizedStrategy"];

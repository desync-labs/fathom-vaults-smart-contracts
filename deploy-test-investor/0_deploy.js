module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const performanceFee = 1000; // 10% of gain

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

module.exports.tags = ["Factory","GenericAccountant","Token"];

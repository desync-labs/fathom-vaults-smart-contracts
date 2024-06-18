const { ethers } = require("hardhat");

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const performanceFee = 1000; // 10% of gain
    // const asset = "0xDf29cB40Cb92a1b8E8337F542E3846E185DefF96"; // DAI
    // const factory = "0xE3E22410ea34661F2b7d5c13EDf7b0c069BD4153";
    // const depositEndsAt = 1718719200;
    // const lockEndsAt = 1718805600;

    await deploy("GenericAccountant", {
        from: deployer,
        args: [performanceFee, deployer, deployer],
        log: true,
    });

    const vaultLogic = await deploy("VaultLogic", {
        from: deployer,
        args: [],
        log: true,
    });


    const vault = await deploy("VaultPackage", {
        from: deployer,
        args: [],
        log: true,
        libraries: {
            "VaultLogic": vaultLogic.address,
        },
    });

    const tokenizedStrategy = await deploy("TokenizedStrategy", {
        from: deployer,
        args: [factory], // Factory address
        log: true,
    });

    const strategy = await deploy("TradeFintechStrategy", {
        from: deployer,
        args: [
            asset, 
            "Fathom Trade Fintech Strategy 1",
            tokenizedStrategy.address,
            depositEndsAt,
            lockEndsAt,
            ethers.parseEther("1000000"), // 1M FXD
            vault.address,
        ],
        log: true,
    });

    console.log("strategy.address", strategy.address);
    console.log("deployer.address", deployer.address);
    console.log("deployer.address", deployer);

    await deploy("KYCDepositLimitModule", {
        from: deployer,
        args: [strategy.address, deployer],
        log: true,
    });




};

module.exports.tags = ["GenericAccountant","Token"];

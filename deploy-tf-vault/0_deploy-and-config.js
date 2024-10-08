const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

const getTheAbi = (contract) => {
    try {
        const dir = path.join(__dirname, "..", "deployments", "apothem", `${contract}.json`);
        const json = JSON.parse(fs.readFileSync(dir, "utf8"));
        return json;
    } catch (e) {
        console.log(`e`, e);
    }
};

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const uint256max = ethers.MaxUint256;

    const assetAddress = "0x49d3f7543335cf38Fa10889CCFF10207e22110B5";
    const factoryAddress = "0x0c6e3fd64D5f33eac0DCCDd887A8c7512bCDB7D6";
    const processingBot = "0x716fb962A0295b5dB0a0Ee1125f52c067aA4D8f1";

    const depositEndsAt = 1720598400; // Thursday, July 10, 2024 12:00:00 PM
    const lockEndsAt = 1736496000; // Friday, January 10, 2025 12:00:00 PM
    const depositLimit = ethers.parseEther("50000000") // 50M FXD
    const minimumDeposit = ethers.parseEther("10000"); // 10,000 FXD
    const profitMaxUnlockTime = 0;

    const strategyName = "TradeFlow Strategy #1";
    const vaultTokenName = "Fathom Vault TradeFi Token";
    const vaultTokenSymbol = "fvTFT";

    const factory = await ethers.getContractAt("IFactoryOld", factoryAddress);
    const asset = await ethers.getContractAt("ERC20", assetAddress);

    const accountant = "0x427Fd46B341C5a3E1eA19BE11D36E5c526A885d4"
    const vaultLogic = await deploy("VaultLogic", {
        from: deployer,
        args: [],
        log: true,
    });
    const vaultPackage = await deploy("VaultPackage", {
        from: deployer,
        args: [],
        log: true,
        libraries: {
            "VaultLogic": vaultLogic.address,
        },
    });
    const tokenizedStrategy = await deploy("TokenizedStrategy", {
        from: deployer,
        args: [factoryAddress], // Factory address
        log: true,
    });

    // return; // Comment this line to continue

    console.log("Updating Vault Package ...");
    const updateVaultPackageTx = await factory.updateVaultPackage(vaultPackage.address);
    await updateVaultPackageTx.wait();

    console.log("Deploying Vault ...");
    const deployVaultTx = await factory.deployVault(
        profitMaxUnlockTime,
        1, // assetType
        assetAddress,
        vaultTokenName,
        vaultTokenSymbol,
        accountant,
        deployer
    );
    await deployVaultTx.wait();

    const vaults = await factory.getVaults();
    console.log("Existing Vaults = ", vaults);
    const vaultsCopy = [...vaults];
    const vaultAddress = vaultsCopy.pop();

    const vault = await ethers.getContractAt("VaultPackage", vaultAddress);
    console.log("The Last Vault Address = ", vaultAddress);

    const strategy = await deploy("TradeFintechStrategy", {
        from: deployer,
        args: [
            assetAddress, 
            strategyName,
            tokenizedStrategy.address,
            depositEndsAt,
            lockEndsAt,
            depositLimit,
            vaultAddress,
        ],
        log: true,
    });


    console.log("Deploying KYC Deposit Limit Module ...");
    const kycDepositLimitModule = await deploy("KYCDepositLimitModule", {
        from: deployer,
        args: [strategy.address, vaultAddress, deployer],
        log: true,
    });
    console.log("KYC Deposit Limit Module Address = ", kycDepositLimitModule.address);

    const STRATEGY_MANAGER = ethers.keccak256(ethers.toUtf8Bytes("STRATEGY_MANAGER"));
    const REPORTING_MANAGER = ethers.keccak256(ethers.toUtf8Bytes("REPORTING_MANAGER"));
    const DEBT_PURCHASER = ethers.keccak256(ethers.toUtf8Bytes("DEBT_PURCHASER"));

    let grantRoleTx = await vault.grantRole(STRATEGY_MANAGER, deployer);
    await grantRoleTx.wait();
    grantRoleTx = await vault.grantRole(STRATEGY_MANAGER, processingBot);
    await grantRoleTx.wait();
    grantRoleTx = await vault.grantRole(REPORTING_MANAGER, deployer);
    await grantRoleTx.wait();
    grantRoleTx = await vault.grantRole(DEBT_PURCHASER, deployer);
    await grantRoleTx.wait();

    console.log("Roles granted ...");

    // Set new manager
    // await strategy.setPendingManagement(address);
    // await strategy.acceptManagement();

    const tStrategy = await ethers.getContractAt("TokenizedStrategy", strategy.address);
    
    console.log("Setting profit max unlock time...");
    const setProfitMaxUnlockTx = await tStrategy.setProfitMaxUnlockTime(0);
    await setProfitMaxUnlockTx.wait();

    console.log("Setting keeper...");
    const setKeeperTx = await tStrategy.setKeeper(deployer);
    await setKeeperTx.wait();

    console.log("Setting deposit limit...");
    const setDepositLimitTx = await vault.setDepositLimit(uint256max);
    await setDepositLimitTx.wait();

    console.log("Setting deposit limit module...");
    const setDepositLimitModuleTx = await vault.setDepositLimitModule(kycDepositLimitModule.address);
    await setDepositLimitModuleTx.wait();

    console.log("Adding strategy...");
    const addStrategy = await vault.addStrategy(strategy.address);
    await addStrategy.wait();

    console.log("Setting max debt for strategy...");
    const setMaxDebt = await vault.updateMaxDebtForStrategy(strategy.address, depositLimit);
    await setMaxDebt.wait();
    // Set minimum deposit

    console.log("Setting minimum deposit...");
    const setMinDeposit = await vault.setMinUserDeposit(minimumDeposit);
    await setMinDeposit.wait();

    console.log("Done ...");
    console.log("strategy.address", strategy.address);
    console.log("deployer.address", deployer);
    console.log("vault.address", vaultAddress);
    console.log("kycDepositLimitModule.address", kycDepositLimitModule.address);
};
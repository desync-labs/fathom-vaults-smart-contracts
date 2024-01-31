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
    let depositLimit = ethers.parseUnits("1000000", 18);
    const maxDebt = ethers.parseUnits("1000000", 18);
    const profitMaxUnlockTime = 604800; // 1 week in seconds
    const protocolFee = 2000; // 20% of total fee

    const vaultTokenName = "FXD-fVault-1";
    const vaultTokenSymbol = "fvFXD1";

    const { deployer } = await getNamedAccounts();

    const factoryFile = getTheAbi("Factory");
    const accountantFile = getTheAbi("GenericAccountant");
    const strategyFile = getTheAbi("InvestorStrategy");
    const vaultPackageFile = getTheAbi("VaultPackage");

    const assetAddress = "0x0000000000000000000000000000000000000000"; // Real asset address

    if (assetAddress === "0x0000000000000000000000000000000000000000") {
        console.log("4_init - Error: Please provide a real asset address");
        return;
    }

    const strategyAddress = strategyFile.address;
    const strategy = await ethers.getContractAt("TokenizedStrategy", strategyAddress);

    const accountantAddress = accountantFile.address;

    const vaultPackageAddress = vaultPackageFile.address;

    const factoryAddress = factoryFile.address;
    const factory = await ethers.getContractAt("FactoryPackage", factoryAddress);

    const factoryInitTx = await factory.initialize(vaultPackageAddress, deployer, protocolFee);
    await factoryInitTx.wait();

    const deployVaultTx = await factory.deployVault(
        profitMaxUnlockTime,
        assetAddress,
        vaultTokenName,
        vaultTokenSymbol,
        accountantAddress,
        deployer
    );
    await deployVaultTx.wait();
    const vaults = await factory.getVaults();
    console.log("Existing Vaults = ", vaults);
    const vaultsCopy = [...vaults];
    const vaultAddress = vaultsCopy.pop();
    const vault = await ethers.getContractAt("VaultPackage", vaultAddress);
    console.log("The Last Vault Address = ", vaultAddress);

    console.log("Setting deposit limit...");
    const setDepositLimitTx = await vault.setDepositLimitAndModule(depositLimit, ethers.ZeroAddress);
    await setDepositLimitTx.wait(); // Wait for the transaction to be confirmed

    console.log("Adding Strategy to the Vault...");
    const addStrategyTx = await vault.addStrategy(strategy.target);
    await addStrategyTx.wait();
    console.log("Setting Vault's Strategy maxDebt...");
    const updateMaxDebtForStrategyTx = await vault.updateMaxDebtForStrategy(strategy.target, maxDebt);
    await updateMaxDebtForStrategyTx.wait();
};

module.exports.tags = ["Init"];

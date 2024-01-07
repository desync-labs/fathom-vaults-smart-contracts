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
    const depositLimit = ethers.parseUnits("1000000", 18);
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
    const investorFile = getTheAbi("Investor");

    const assetAddress = "0x"; // Real asset address
    const asset = await ethers.getContractAt("ERC20", assetAddress);

    const strategyAddress = strategyFile.address;
    const strategy = await ethers.getContractAt("InvestorStrategy", strategyAddress);

    const investorAddress = investorFile.address;
    const investor = await ethers.getContractAt("Investor", investorAddress);

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
    const setDepositLimitTx = await vault.setDepositLimit(depositLimit, { gasLimit: "0x1000000" });
    await setDepositLimitTx.wait(); // Wait for the transaction to be confirmed

    console.log("Updating balances...");
    let balanceInShares = await vault.balanceOf(deployer);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    let balanceInTokens = await vault.convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    let balanceVaultInShares = await vault.balanceOf(vaultAddress);
    console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    let balanceVaultInTokens = await asset.balanceOf(vaultAddress);
    console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    let balanceStrategy = await asset.balanceOf(strategy.target);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    let accountantShares = await vault.balanceOf(accountantAddress);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));

    // Setup Strategy
    console.log("Adding Strategy to the Vault...");
    const addStrategyTx = await vault.addStrategy(strategy.target, { gasLimit: "0x1000000" });
    await addStrategyTx.wait();
    console.log("Setting Vault's Strategy maxDebt...");
    const updateMaxDebtForStrategyTx = await vault.updateMaxDebtForStrategy(strategy.target, maxDebt, { gasLimit: "0x1000000" });
    await updateMaxDebtForStrategyTx.wait();
    console.log("Update Vault's Strategy debt...");
    const updateDebtTx = await vault.updateDebt(strategy.target, balanceVaultInTokens, { gasLimit: "0x1000000" });
    await updateDebtTx.wait();
};

module.exports.tags = ["Init"];

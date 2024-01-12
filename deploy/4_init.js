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
    const profitMaxUnlockTime = 300; // 1 week in seconds
    const protocolFee = 2000; // 20% of total fee
    const amount = ethers.parseUnits("1000000", 18);
    const depositAmount = ethers.parseUnits("10", 18);
    let gain = ethers.parseUnits("5", 18);

    const vaultTokenName = "FXD-fVault-1";
    const vaultTokenSymbol = "fvFXD1";

    const { deployer } = await getNamedAccounts();

    const factoryFile = getTheAbi("Factory");
    const accountantFile = getTheAbi("GenericAccountant");
    const strategyFile = getTheAbi("InvestorStrategy");
    const vaultPackageFile = getTheAbi("VaultPackage");
    const investorFile = getTheAbi("Investor");

    const assetAddress = "0xDf29cB40Cb92a1b8E8337F542E3846E185DefF96"; // Real asset address
    const asset = await ethers.getContractAt("ERC20", assetAddress);

    const strategyAddress = strategyFile.address;
    const strategy = await ethers.getContractAt("TokenizedStrategy", strategyAddress);

    const investorAddress = investorFile.address;
    const investor = await ethers.getContractAt("Investor", investorAddress);

    const accountantAddress = accountantFile.address;

    const vaultPackageAddress = vaultPackageFile.address;

    const factoryAddress = factoryFile.address;
    const factory = await ethers.getContractAt("FactoryPackage", factoryAddress);

    const factoryInitTx = await factory.initialize(vaultPackageAddress, deployer, protocolFee, { gasLimit: "0x1000000" });
    await factoryInitTx.wait();

    const deployVaultTx = await factory.deployVault(
        profitMaxUnlockTime,
        assetAddress,
        vaultTokenName,
        vaultTokenSymbol,
        accountantAddress,
        deployer, 
        { gasLimit: "0x1000000" }
    );
    await deployVaultTx.wait();
    const vaults = await factory.getVaults();
    console.log("Existing Vaults = ", vaults);
    const vaultsCopy = [...vaults];
    const vaultAddress = vaultsCopy.pop();
    const vault = await ethers.getContractAt("VaultPackage", vaultAddress);
    console.log("The Last Vault Address = ", vaultAddress);

    // Simulate a deposit
    console.log("Setting deposit limit...");
    const setDepositLimitTx = await vault.setDepositLimit(depositLimit, { gasLimit: "0x1000000" });
    await setDepositLimitTx.wait(); // Wait for the transaction to be confirmed
    console.log("Approving tokens...");
    const approveTx = await asset.approve(vaultAddress, amount, { gasLimit: "0x1000000" });
    await approveTx.wait(); // Wait for the transaction to be confirmed
    console.log("Depositing...");
    const depositTx = await vault.deposit(depositAmount, deployer, { gasLimit: "0x1000000" });
    await depositTx.wait(); // Wait for the transaction to be confirmed

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
    console.log("Depositing to Investor...");

    console.log("Approving tokens...");
    const approveInvestorTx = await asset.approve(investor.target, gain, { gasLimit: "0x1000000" });
    await approveInvestorTx.wait(); // Wait for the transaction to be confirmed
    let blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
    console.log("Block Timestamp = ", blockTimestamp);
    const startDistribution = blockTimestamp + 10;
    const endDistribution = blockTimestamp + 11;
    console.log("Distribution start time = ", startDistribution);
    console.log("Distribution end time = ", endDistribution);
    
    const depositToInvestorTx = await investor.setupDistribution(
        gain,
        startDistribution,
        endDistribution
    );
    await depositToInvestorTx.wait(); // Wait for the transaction to be confirmed

    console.log("Sleeping for 10 seconds to allow distribution to start...");
    await new Promise(r => setTimeout(r, 11000));

    console.log("Adding Strategy to the Vault...");
    const addStrategyTx = await vault.addStrategy(strategy.target, { gasLimit: "0x1000000" });
    await addStrategyTx.wait();
    console.log("Setting Vault's Strategy maxDebt...");
    const updateMaxDebtForStrategyTx = await vault.updateMaxDebtForStrategy(strategy.target, maxDebt, { gasLimit: "0x1000000" });
    await updateMaxDebtForStrategyTx.wait();
    console.log("Update Vault's Strategy debt...");
    const updateDebtTx = await vault.updateDebt(strategy.target, balanceVaultInTokens, { gasLimit: "0x1000000" });
    await updateDebtTx.wait();

    console.log("Updating balances...");
    balanceInShares = await vault.balanceOf(deployer);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    balanceInTokens = await vault.convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    balanceVaultInShares = await vault.balanceOf(vaultAddress);
    console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    balanceVaultInTokens = await asset.balanceOf(vaultAddress);
    console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    balanceStrategy = await asset.balanceOf(strategy.target);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    accountantShares = await vault.balanceOf(accountantAddress);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));

    console.log("Creating profit for Strategy...");
    const distributionTx = await investor.processReport({ gasLimit: "0x1000000" });
    await distributionTx.wait();
    console.log("Create report for Strategy...");
    const reportTx = await strategy.report({ gasLimit: "0x1000000" });
    await reportTx.wait();
    blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
    console.log("Block Timestamp = ", blockTimestamp);
    console.log("Process report for Strategy on Vault...");
    const processReportTx = await vault.processReport(strategy.target, { gasLimit: "0x1000000" });
    await processReportTx.wait();
    let fullProfitUnlockDate = (await vault.fullProfitUnlockDate()).toString();
    console.log("Full Profit Unlock Date = ", fullProfitUnlockDate);

    // Sleep for 60 seconds
    console.log("Sleeping for 60 seconds...");
    await new Promise(r => setTimeout(r, 60000));

    console.log("Create second report for Strategy after sleeping...");
    const reportTx2 = await strategy.report({ gasLimit: "0x1000000" });
    await reportTx2.wait();
    blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
    console.log("Block Timestamp = ", blockTimestamp);
    console.log("Process second report for Strategy on Vault after sleeping...");
    const processReportTx2 = await vault.processReport(strategy.target, { gasLimit: "0x1000000" });
    await processReportTx2.wait();

    console.log("Updating balances...");
    balanceInShares = await vault.balanceOf(deployer);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    balanceInTokens = await vault.convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    balanceVaultInShares = await vault.balanceOf(vaultAddress);
    console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    balanceVaultInTokens = await asset.balanceOf(vaultAddress);
    console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    balanceStrategy = await asset.balanceOf(strategy.target);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    accountantShares = await vault.balanceOf(accountantAddress);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));

    // Sleep for another 60 seconds
    console.log("Sleeping for 60 seconds...");
    await new Promise(r => setTimeout(r, 60000));

    console.log("Create third report for Strategy after sleeping...");
    const reportTx3 = await strategy.report({ gasLimit: "0x1000000" });
    await reportTx3.wait();
    blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
    console.log("Block Timestamp = ", blockTimestamp);
    console.log("Process third report for Strategy on Vault after sleeping...");
    const processReportTx3 = await vault.processReport(strategy.target, { gasLimit: "0x1000000" });
    await processReportTx3.wait();

    console.log("Updating balances...");
    balanceInShares = await vault.balanceOf(deployer);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    balanceInTokens = await vault.convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    balanceVaultInShares = await vault.balanceOf(vaultAddress);
    console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    balanceVaultInTokens = await asset.balanceOf(vaultAddress);
    console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    balanceStrategy = await asset.balanceOf(strategy.target);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    accountantShares = await vault.balanceOf(accountantAddress);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));

    // Simulate a redeem
    console.log("Redeeming...");
    const redeemTx = await vault.redeem(balanceInShares, deployer, deployer, 0, [], { gasLimit: "0x1000000" });
    await redeemTx.wait();

    console.log("Updating balances...");
    balanceInShares = await vault.balanceOf(deployer);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    balanceInTokens = await vault.convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    balanceVaultInShares = await vault.balanceOf(vaultAddress);
    console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    balanceVaultInTokens = await asset.balanceOf(vaultAddress);
    console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    balanceStrategy = await asset.balanceOf(strategy.target);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    accountantShares = await vault.balanceOf(accountantAddress);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));
};

module.exports.tags = ["Init"];

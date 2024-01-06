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
    const amount = ethers.parseUnits("1000000", 18);
    const depositAmount = ethers.parseUnits("1000", 18);
    const withdrawAmount = ethers.parseUnits("9", 18);
    const redeemAmount = ethers.parseUnits("10", 18);
    const maxDebt = ethers.parseUnits("1000", 18);
    const debt = ethers.parseUnits("200", 18);
    const newDebt = ethers.parseUnits("0", 18);
    const profit = ethers.parseUnits("100", 18);
    const profitMaxUnlockTime = 60; // 1 year in seconds
    const protocolFee = 2000;

    const vaultTokenName = "Vault Shares FXD";
    const vaultTokenSymbol = "vFXD";

    const { deployer } = await getNamedAccounts();
    const recipientAddress = "0x0db96Eb1dc48554bB0f8203A6dE449B2FcCF51a6"

    const factoryFile = getTheAbi("Factory");
    const accountantFile = getTheAbi("GenericAccountant");
    const tokenFile = getTheAbi("Token");
    const strategyFile = getTheAbi("MockTokenizedStrategy");
    const vaultPackageFile = getTheAbi("VaultPackage");

    const assetAddress = tokenFile.address;
    const asset = await ethers.getContractAt("Token", assetAddress);

    const strategyAddress = strategyFile.address;
    const strategy = await ethers.getContractAt("MockTokenizedStrategy", strategyAddress);

    const accountantAddress = accountantFile.address;

    const vaultPackageAddress = vaultPackageFile.address;

    const factoryAddress = factoryFile.address;
    const factory = await ethers.getContractAt("FactoryPackage", factoryAddress);

    const factoryInitTx = await factory.initialize(vaultPackageAddress, recipientAddress, protocolFee);
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

    console.log("Minting tokens...");
    const mintTx = await asset.mint(deployer, amount, { gasLimit: "0x1000000" });
    await mintTx.wait(); // Wait for the transaction to be confirmed
    console.log("Approving tokens...");
    const approveTx = await asset.approve(vaultAddress, amount, { gasLimit: "0x1000000" });
    await approveTx.wait(); // Wait for the transaction to be confirmed
    console.log("Setting deposit limit...");
    const setDepositLimitTx = await vault.setDepositLimit(amount, { gasLimit: "0x1000000" });
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
    let recipientShares = await vault.balanceOf(recipientAddress);
    console.log("Shares of Fee Recipient = ", ethers.formatUnits(recipientShares, 18));
    let accountantShares = await vault.balanceOf(accountantAddress);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));

    // Simulate a deposit
    console.log("Depositing...");
    const depositTx = await vault.deposit(depositAmount, deployer, { gasLimit: "0x1000000" });
    await depositTx.wait(); // Wait for the transaction to be confirmed

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

    let gain = Math.floor(ethers.formatUnits(balanceVaultInTokens, 18) / 2);
    gain = ethers.parseUnits(gain.toString(), 18);

    // Simulate Strategy
    console.log("Adding Strategy to the Vault...");
    const addStrategyTx = await vault.addStrategy(strategy.target, { gasLimit: "0x1000000" });
    await addStrategyTx.wait();
    console.log("Setting Strategy maxDebt...");
    const setMaxDebtTx = await strategy.setMaxDebt(ethers.MaxUint256, { gasLimit: "0x1000000" });
    await setMaxDebtTx.wait();
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
    let pricePerShare = await vault.pricePerShare();
    console.log("Price Per Share = ", ethers.formatUnits(pricePerShare, 18));
    let vaultStrategyBalance = await strategy.balanceOf(vaultAddress);
    console.log("Vault Balance on Strategy = ", ethers.formatUnits(vaultStrategyBalance, 18));
    let vaultStrategyBalanceInTokens = await strategy.convertToAssets(vaultStrategyBalance);
    console.log("Vault Balance on Strategy in Tokens = ", ethers.formatUnits(vaultStrategyBalanceInTokens, 18));
    recipientShares = await vault.balanceOf(recipientAddress);
    console.log("Shares of Fee Recipient = ", ethers.formatUnits(recipientShares, 18));
    accountantShares = await vault.balanceOf(accountantAddress);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));
    let fullProfitUnlockDate = (await vault.fullProfitUnlockDate()).toString();
    console.log("Full Profit Unlock Date = ", fullProfitUnlockDate);

    console.log("Creating profit for Strategy...");
    const transferTx = await asset.transfer(strategy.target, gain, { gasLimit: "0x1000000" });
    await transferTx.wait();
    console.log("Create report for Strategy...");
    const reportTx = await strategy.report({ gasLimit: "0x1000000" });
    await reportTx.wait();
    let blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
    console.log("Block Timestamp = ", blockTimestamp);
    console.log("Process report for Strategy on Vault...");
    const processReportTx = await vault.processReport(strategy.target, { gasLimit: "0x1000000" });
    await processReportTx.wait();
    fullProfitUnlockDate = (await vault.fullProfitUnlockDate()).toString();
    console.log("Full Profit Unlock Date = ", fullProfitUnlockDate);

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
    pricePerShare = await vault.pricePerShare();
    console.log("Price Per Share = ", ethers.formatUnits(pricePerShare, 18));
    vaultStrategyBalance = await strategy.balanceOf(vaultAddress);
    console.log("Vault Balance on Strategy = ", ethers.formatUnits(vaultStrategyBalance, 18));
    vaultStrategyBalanceInTokens = await strategy.convertToAssets(vaultStrategyBalance);
    console.log("Vault Balance on Strategy in Tokens = ", ethers.formatUnits(vaultStrategyBalanceInTokens, 18));
    recipientShares = await vault.balanceOf(recipientAddress);
    console.log("Shares of Fee Recipient = ", ethers.formatUnits(recipientShares, 18));
    accountantShares = await vault.balanceOf(accountantAddress);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));

    // Sleep for 60 seconds
    console.log("Sleeping for 60 seconds...");
    await new Promise(r => setTimeout(r, 60000));

    // console.log("Update Vault's Strategy debt...");
    // const updateDebtTx2 = await vault.updateDebt(strategy.target, 0, { gasLimit: "0x1000000" });
    // await updateDebtTx2.wait();
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
    pricePerShare = await vault.pricePerShare();
    console.log("Price Per Share = ", ethers.formatUnits(pricePerShare, 18));
    vaultStrategyBalance = await strategy.balanceOf(vaultAddress);
    console.log("Vault Balance on Strategy = ", ethers.formatUnits(vaultStrategyBalance, 18));
    vaultStrategyBalanceInTokens = await strategy.convertToAssets(vaultStrategyBalance);
    console.log("Vault Balance on Strategy in Tokens = ", ethers.formatUnits(vaultStrategyBalanceInTokens, 18));
    recipientShares = await vault.balanceOf(recipientAddress);
    console.log("Shares of Fee Recipient = ", ethers.formatUnits(recipientShares, 18));
    accountantShares = await vault.balanceOf(accountantAddress);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));
    fullProfitUnlockDate = (await vault.fullProfitUnlockDate()).toString();
    console.log("Full Profit Unlock Date = ", fullProfitUnlockDate);

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
    pricePerShare = await vault.pricePerShare();
    console.log("Price Per Share = ", ethers.formatUnits(pricePerShare, 18));
    vaultStrategyBalance = await strategy.balanceOf(vaultAddress);
    console.log("Vault Balance on Strategy = ", ethers.formatUnits(vaultStrategyBalance, 18));
    vaultStrategyBalanceInTokens = await strategy.convertToAssets(vaultStrategyBalance);
    console.log("Vault Balance on Strategy in Tokens = ", ethers.formatUnits(vaultStrategyBalanceInTokens, 18));
    recipientShares = await vault.balanceOf(recipientAddress);
    console.log("Shares of Fee Recipient = ", ethers.formatUnits(recipientShares, 18));
    accountantShares = await vault.balanceOf(accountantAddress);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));
    fullProfitUnlockDate = (await vault.fullProfitUnlockDate()).toString();
    console.log("Full Profit Unlock Date = ", fullProfitUnlockDate);

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
    vaultStrategyBalanceInTokens = await strategy.convertToAssets(vaultStrategyBalance);
    console.log("Price Per Share = ", ethers.formatUnits(pricePerShare, 18));
    vaultStrategyBalance = await strategy.balanceOf(vaultAddress);
    console.log("Vault Balance on Strategy in Tokens = ", ethers.formatUnits(vaultStrategyBalanceInTokens, 18));
    recipientShares = await vault.balanceOf(recipientAddress);
    console.log("Shares of Fee Recipient = ", ethers.formatUnits(recipientShares, 18));
    accountantShares = await vault.balanceOf(accountantAddress);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));
    fullProfitUnlockDate = (await vault.fullProfitUnlockDate()).toString();
    console.log("Full Profit Unlock Date = ", fullProfitUnlockDate);
    blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
    console.log("Block Timestamp = ", blockTimestamp);

    console.log("Setting deposit limit...");
    const setDepositLimitTx2 = await vault.setDepositLimit(amount, { gasLimit: "0x1000000" });
    await setDepositLimitTx2.wait(); // Wait for the transaction to be confirmed

    // const withdrawTxAfter = await vault.withdraw(balanceInTokens, deployer, deployer, 0, [], { gasLimit: "0x1000000" });
    // // const withdrawTx = await vault.withdraw(withdrawAmount, deployer, deployer, 0, [], { gasLimit: "0x1000000" });
    // await withdrawTxAfter.wait();

    // Additional initialization steps as needed...

    // // Preview Redeem
    // console.log("Previewing redeem...");
    // const sharesAmount = ethers.parseUnits("1000", 18);
    // let amountPreviewed = await vault.previewRedeem(sharesAmount);
    // console.log("Amount of tokens previewed = ", ethers.formatUnits(amountPreviewed, 18));
};

module.exports.tags = ["Init"];

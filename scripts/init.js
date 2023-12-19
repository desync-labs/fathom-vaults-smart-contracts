// scripts/initializeVault.js

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
    const { deployer } = await getNamedAccounts();
    const vaultFile = getTheAbi("FathomVault");
    const tokenFile = getTheAbi("Token");
    const sharesManagerFile = getTheAbi("SharesManager");
    const strategyManagerFile = getTheAbi("StrategyManager");
    const strategyFile = getTheAbi("MockTokenizedStrategy");
    const settersFile = getTheAbi("Setters");

    const vaultAddress = vaultFile.address;
    // const assetAddress = tokenFile.address;
    const assetAddress = "0xdf29cb40cb92a1b8e8337f542e3846e185deff96";
    const sharesManagerAddress = sharesManagerFile.address;
    const strategyManagerAddress = strategyManagerFile.address;
    const strategyAddress = strategyFile.address;
    const settersAddress = settersFile.address;

    const vault = await ethers.getContractAt("FathomVault", vaultAddress);
    const asset = await ethers.getContractAt("Token", assetAddress);
    const sharesManager = await ethers.getContractAt("SharesManager", sharesManagerAddress);
    const strategyManager = await ethers.getContractAt("StrategyManager", strategyManagerAddress);
    const strategy = await ethers.getContractAt("MockTokenizedStrategy", strategyAddress);
    const setters = await ethers.getContractAt("Setters", settersAddress);

    const [owner, addr1, addr2] = await ethers.getSigners();
    const recipientAddress = "0x0db96Eb1dc48554bB0f8203A6dE449B2FcCF51a6"

    const amount = ethers.parseUnits("1000000", 18);
    const depositAmount = ethers.parseUnits("1000", 18);
    const withdrawAmount = ethers.parseUnits("9", 18);
    const redeemAmount = ethers.parseUnits("10", 18);
    const maxDebt = ethers.parseUnits("1000", 18);
    const debt = ethers.parseUnits("200", 18);
    const newDebt = ethers.parseUnits("0", 18);
    const profit = ethers.parseUnits("100", 18);

    console.log("Updating balances...");
    let balanceInShares = await vault.connect(owner).balanceOf(owner.address);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    let balanceInTokens = await vault.connect(owner).convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    let balanceSharesManager = await asset.connect(owner).balanceOf(sharesManagerAddress);
    console.log("Balance of Shares Manager = ", ethers.formatUnits(balanceSharesManager, 18));
    let balanceStrategy = await asset.connect(owner).balanceOf(strategy.target);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    let recipientShares = await sharesManager.connect(owner).balanceOf(recipientAddress);
    console.log("Shares of Recipient = ", ethers.formatUnits(recipientShares, 18));

    // Initialization logic
    console.log("Initializing vault...");
    const initializeTx = await sharesManager.connect(owner).initialize(strategyManagerAddress, settersAddress, { gasLimit: "0x1000000" });
    await initializeTx.wait();
    // console.log("Minting tokens...");
    // const mintTx = await asset.connect(owner).mint(owner.address, amount, { gasLimit: "0x1000000" });
    // await mintTx.wait(); // Wait for the transaction to be confirmed
    console.log("Approving tokens...");
    const approveTx = await asset.connect(owner).approve(sharesManager.target, amount, { gasLimit: "0x1000000" });
    await approveTx.wait(); // Wait for the transaction to be confirmed
    console.log("Setting deposit limit...");
    const setDepositLimitTx = await vault.connect(owner).setDepositLimit(amount, { gasLimit: "0x1000000" });
    await setDepositLimitTx.wait(); // Wait for the transaction to be confirmed

    // Simulate a deposit
    console.log("Depositing...");
    const depositTx = await vault.connect(owner).deposit(depositAmount, owner.address, { gasLimit: "0x1000000" });
    await depositTx.wait(); // Wait for the transaction to be confirmed

    // Simulate a withdraw
    console.log("Updating balances...");
    balanceInShares = await vault.connect(owner).balanceOf(owner.address);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    balanceInTokens = await vault.connect(owner).convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    balanceSharesManager = await asset.connect(owner).balanceOf(sharesManagerAddress);
    console.log("Balance of Shares Manager = ", ethers.formatUnits(balanceSharesManager, 18));
    balanceStrategy = await asset.connect(owner).balanceOf(strategy.target);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));

    let gain = Math.floor(ethers.formatUnits(balanceSharesManager, 18) / 2);
    gain = ethers.parseUnits(gain.toString(), 18);

    // Simulate Strategy
    console.log("Adding Strategy to the Vault...");
    const addStrategyTx = await vault.connect(owner).addStrategy(strategy.target, { gasLimit: "0x1000000" });
    await addStrategyTx.wait();
    console.log("Setting Strategy maxDebt...");
    const setMaxDebtTx = await strategy.connect(owner).setMaxDebt(ethers.MaxUint256, { gasLimit: "0x1000000" });
    await setMaxDebtTx.wait();
    console.log("Setting Vault's Strategy maxDebt...");
    const updateMaxDebtForStrategyTx = await vault.connect(owner).updateMaxDebtForStrategy(strategy.target, maxDebt, { gasLimit: "0x1000000" });
    await updateMaxDebtForStrategyTx.wait();
    console.log("Update Vault's Strategy debt...");
    const updateDebtTx = await vault.connect(owner).updateDebt(sharesManagerAddress, strategy.target, balanceSharesManager, { gasLimit: "0x1000000" });
    await updateDebtTx.wait();

    console.log("Updating balances...");
    balanceInShares = await vault.connect(owner).balanceOf(owner.address);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    balanceInTokens = await vault.connect(owner).convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    balanceSharesManager = await asset.connect(owner).balanceOf(sharesManagerAddress);
    console.log("Balance of Shares Manager = ", ethers.formatUnits(balanceSharesManager, 18));
    balanceStrategy = await asset.connect(owner).balanceOf(strategy.target);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    let pricePerShare = await vault.connect(owner).pricePerShare();
    console.log("Price Per Share = ", ethers.formatUnits(pricePerShare, 18));
    let sharesManagerStrategyBalance = await strategy.connect(owner).balanceOf(sharesManagerAddress);
    console.log("Shares Manager Balance on Strategy = ", ethers.formatUnits(sharesManagerStrategyBalance, 18));
    let sharesManagerStrategyBalanceInTokens = await strategy.connect(owner).convertToAssets(sharesManagerStrategyBalance);
    console.log("Shares Manager Balance on Strategy in Tokens = ", ethers.formatUnits(sharesManagerStrategyBalanceInTokens, 18));
    recipientShares = await sharesManager.connect(owner).balanceOf(recipientAddress);
    console.log("Shares of Recipient = ", ethers.formatUnits(recipientShares, 18));

    // Set fees
    console.log("Setting fees...");
    const setFeesTx = await vault.connect(owner).setFees(
        BigInt(10), // totalFees in percentage
        BigInt(0),    // totalRefunds
        BigInt(10), // protocolFees in percentage
        recipientAddress, // feesRecipient
        { gasLimit: "0x1000000" }
    );
    await setFeesTx.wait();
    console.log("Fees set successfully.");

    // Showing fees
    console.log("Showing fees...");
    const fees = await strategyManager.connect(owner).fees(); // Adjust according to your contract
    console.log("Total Fees = ", fees.totalFees);
    console.log("Total Refunds = ", fees.totalRefunds);
    console.log("Protocol Fees = ", fees.protocolFees);
    console.log("Protocol Fee Recipient = ", fees.protocolFeeRecipient);


    console.log("Creating profit for Strategy...");
    const transferTx = await asset.connect(owner).transfer(strategy.target, gain, { gasLimit: "0x1000000" });
    await transferTx.wait();
    console.log("Create report for Strategy...");
    const reportTx = await strategy.connect(owner).report({ gasLimit: "0x1000000" });
    await reportTx.wait();
    console.log("Process report for Strategy on Vault...");
    const processReportTx = await vault.connect(owner).processReport(strategy.target, { gasLimit: "0x1000000" });
    await processReportTx.wait();

    console.log("Updating balances...");
    balanceInShares = await vault.connect(owner).balanceOf(owner.address);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    balanceInTokens = await vault.connect(owner).convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    balanceSharesManager = await asset.connect(owner).balanceOf(sharesManagerAddress);
    console.log("Balance of Shares Manager = ", ethers.formatUnits(balanceSharesManager, 18));
    balanceStrategy = await asset.connect(owner).balanceOf(strategy.target);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    pricePerShare = await vault.connect(owner).pricePerShare();
    console.log("Price Per Share = ", ethers.formatUnits(pricePerShare, 18));
    sharesManagerStrategyBalance = await strategy.connect(owner).balanceOf(sharesManagerAddress);
    console.log("Shares Manager Balance on Strategy = ", ethers.formatUnits(sharesManagerStrategyBalance, 18));
    sharesManagerStrategyBalanceInTokens = await strategy.connect(owner).convertToAssets(sharesManagerStrategyBalance);
    console.log("Shares Manager Balance on Strategy in Tokens = ", ethers.formatUnits(sharesManagerStrategyBalanceInTokens, 18));
    recipientShares = await sharesManager.connect(owner).balanceOf(recipientAddress);
    console.log("Shares of Recipient = ", ethers.formatUnits(recipientShares, 18));

    // Sleep for 60 seconds
    console.log("Sleeping for 60 seconds...");
    await new Promise(r => setTimeout(r, 60000));

    console.log("Create second report for Strategy after sleeping...");
    const reportTx2 = await strategy.connect(owner).report({ gasLimit: "0x1000000" });
    await reportTx2.wait();
    console.log("Process second report for Strategy on Vault after sleeping...");
    const processReportTx2 = await vault.connect(owner).processReport(strategy.target, { gasLimit: "0x1000000" });
    await processReportTx2.wait();

    console.log("Updating balances...");
    balanceInShares = await vault.connect(owner).balanceOf(owner.address);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    balanceInTokens = await vault.connect(owner).convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    balanceSharesManager = await asset.connect(owner).balanceOf(sharesManagerAddress);
    console.log("Balance of Shares Manager = ", ethers.formatUnits(balanceSharesManager, 18));
    balanceStrategy = await asset.connect(owner).balanceOf(strategy.target);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    pricePerShare = await vault.connect(owner).pricePerShare();
    console.log("Price Per Share = ", ethers.formatUnits(pricePerShare, 18));
    sharesManagerStrategyBalance = await strategy.connect(owner).balanceOf(sharesManagerAddress);
    console.log("Shares Manager Balance on Strategy = ", ethers.formatUnits(sharesManagerStrategyBalance, 18));
    sharesManagerStrategyBalanceInTokens = await strategy.connect(owner).convertToAssets(sharesManagerStrategyBalance);
    console.log("Shares Manager Balance on Strategy in Tokens = ", ethers.formatUnits(sharesManagerStrategyBalanceInTokens, 18));
    recipientShares = await sharesManager.connect(owner).balanceOf(recipientAddress);
    console.log("Shares of Recipient = ", ethers.formatUnits(recipientShares, 18));

    // Simulate a redeem
    console.log("Redeeming...");
    const redeemTx = await vault.connect(owner).redeem(balanceInShares, owner.address, owner.address, 0, [], { gasLimit: "0x1000000" });
    await redeemTx.wait();

    console.log("Updating balances...");
    balanceInShares = await vault.connect(owner).balanceOf(owner.address);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    balanceInTokens = await vault.connect(owner).convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    balanceSharesManager = await asset.connect(owner).balanceOf(sharesManagerAddress);
    console.log("Balance of Shares Manager = ", ethers.formatUnits(balanceSharesManager, 18));
    balanceStrategy = await asset.connect(owner).balanceOf(strategy.target);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    sharesManagerStrategyBalanceInTokens = await strategy.connect(owner).convertToAssets(sharesManagerStrategyBalance);
    console.log("Price Per Share = ", ethers.formatUnits(pricePerShare, 18));
    sharesManagerStrategyBalance = await strategy.connect(owner).balanceOf(sharesManagerAddress);
    console.log("Shares Manager Balance on Strategy in Tokens = ", ethers.formatUnits(sharesManagerStrategyBalanceInTokens, 18));
    recipientShares = await sharesManager.connect(owner).balanceOf(recipientAddress);
    console.log("Shares of Recipient = ", ethers.formatUnits(recipientShares, 18));

    // const withdrawTxAfter = await vault.connect(owner).withdraw(balanceInTokens, owner.address, owner.address, 0, [], { gasLimit: "0x1000000" });
    // // const withdrawTx = await vault.connect(owner).withdraw(withdrawAmount, owner.address, owner.address, 0, [], { gasLimit: "0x1000000" });
    // await withdrawTxAfter.wait();

    // Additional initialization steps as needed...

    // // Preview Redeem
    // console.log("Previewing redeem...");
    // const sharesAmount = ethers.parseUnits("1000", 18);
    // let amountPreviewed = await vault.connect(owner).previewRedeem(sharesAmount);
    // console.log("Amount of tokens previewed = ", ethers.formatUnits(amountPreviewed, 18));
};

module.exports.tags = ["Init"];

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
    const strategyFile = getTheAbi("MockTokenizedStrategy");

    const vaultAddress = vaultFile.address;
    const assetAddress = tokenFile.address;
    const sharesManagerAddress = sharesManagerFile.address;
    const strategyAddress = strategyFile.address;

    const vault = await ethers.getContractAt("FathomVault", vaultAddress);
    const asset = await ethers.getContractAt("Token", assetAddress);
    const sharesManager = await ethers.getContractAt("SharesManager", sharesManagerAddress);
    const strategy = await ethers.getContractAt("MockTokenizedStrategy", strategyAddress);

    const [owner, addr1, addr2] = await ethers.getSigners();

    const amount = ethers.parseUnits("1000000", 18);
    const depositAmount = ethers.parseUnits("1000", 18);
    const withdrawAmount = ethers.parseUnits("10", 18);
    const redeemAmount = ethers.parseUnits("10", 18);
    const debt = ethers.parseUnits("10", 18);
    const profit = ethers.parseUnits("100", 18);

    // // Initialization logic
    // console.log("Initializing vault...");
    console.log("Minting tokens...");
    const mintTx = await asset.connect(owner).mint("0x0Eb7DEE6e18Cce8fE839E986502d95d47dC0ADa3", amount, { gasLimit: "0x1000000" });
    await mintTx.wait(); // Wait for the transaction to be confirmed
    // console.log("Approving tokens...");
    // const approveTx = await asset.connect(owner).approve(sharesManager.target, amount, { gasLimit: "0x1000000" });
    // await approveTx.wait(); // Wait for the transaction to be confirmed
    // console.log("Setting deposit limit...");
    // const setDepositLimitTx = await vault.connect(owner).setDepositLimit(amount, { gasLimit: "0x1000000" });
    // await setDepositLimitTx.wait(); // Wait for the transaction to be confirmed

    // // Simulate a deposit
    // console.log("Depositing...");
    // const depositTx = await vault.connect(owner).deposit(depositAmount, owner.address, { gasLimit: "0x1000000" });
    // await depositTx.wait(); // Wait for the transaction to be confirmed

    // // Simulate a withdraw
    // console.log("Withdrawing...");
    // const withdrawTx = await vault.connect(owner).withdraw(withdrawAmount, owner.address, owner.address, 0, [], { gasLimit: "0x1000000" });
    // await withdrawTx.wait();

    // // Simulate a redeem
    // console.log("Redeeming...");
    // const redeemTx = await vault.connect(owner).redeem(redeemAmount, owner.address, owner.address, 0, [], { gasLimit: "0x1000000" });
    // await redeemTx.wait();

    // // Simulate Strategy
    // console.log("Adding Strategy to the Vault...");
    // const addStrategyTx = await vault.connect(owner).addStrategy(strategy.target, { gasLimit: "0x1000000" });
    // await addStrategyTx.wait();
    // console.log("Setting Strategy maxDebt...");
    // const setMaxDebtTx = await strategy.connect(owner).setMaxDebt(ethers.MaxUint256, { gasLimit: "0x1000000" });
    // await setMaxDebtTx.wait();
    // console.log("Setting Vault's Strategy maxDebt...");
    // const updateMaxDebtForStrategyTx = await vault.connect(owner).updateMaxDebtForStrategy(strategy.target, debt, { gasLimit: "0x1000000" });
    // await updateMaxDebtForStrategyTx.wait();
    // console.log("Update Vault's Strategy debt...");
    // const updateDebtTx = await vault.connect(owner).updateDebt(strategy.target, debt, { gasLimit: "0x1000000" });
    // await updateDebtTx.wait();
    // console.log("Creating profit for Strategy...");
    // const transferTx = await asset.connect(owner).transfer(strategy.target, profit, { gasLimit: "0x1000000" });
    // await transferTx.wait();
    // console.log("Create report for Strategy...");
    // const reportTx = await strategy.connect(owner).report({ gasLimit: "0x1000000" });
    // await reportTx.wait();
    // console.log("Process report for Strategy on Vault...");
    // const processReportTx = await vault.connect(owner).processReport(strategy.target, { gasLimit: "0x1000000" });
    // const processReportReceipt = await processReportTx.wait();

    // Additional initialization steps as needed...
};

module.exports.tags = ["Init"];

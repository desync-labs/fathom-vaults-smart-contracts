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
    const distributedAmount = ethers.parseUnits("1", "ether");
    const blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
    const distributionTime = 604800; // 1 week in seconds
    const startDistribution = blockTimestamp + 10;
    const endDistribution = blockTimestamp + distributionTime;

    const assetAddress = "0x0000000000000000000000000000000000000000"; // Real asset address

    if (assetAddress === "0x0000000000000000000000000000000000000000") {
        console.log("5_setup_investor_strategy - Error: Please provide a real asset address");
        return;
    }

    const asset = await ethers.getContractAt("Token", assetAddress);

    const investorFile = getTheAbi("Investor");
    const investorAddress = investorFile.address;
    const investor = await ethers.getContractAt("Investor", investorAddress);

    // Setup Investor
    console.log("Setting up Asset Approval...");
    let tx = await asset.approve(investor.target, distributedAmount);
    await tx.wait();
    
    console.log("Setting up Distribution...");
    tx = await investor.setupDistribution(distributedAmount, startDistribution, endDistribution);
    await tx.wait();
};

module.exports.tags = ["SetupInvestorStrategy"];
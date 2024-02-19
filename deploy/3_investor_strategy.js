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

    const asset = "0x0000000000000000000000000000000000000000"; // Real asset address

    if (asset === "0x0000000000000000000000000000000000000000") {
        console.log("3_investor_strategy - Error: Please provide a real asset address");
        return;
    }

    const investorFile = getTheAbi("Investor");
    const investorAddress = investorFile.address;
    const investor = await ethers.getContractAt("Investor", investorAddress);

    const tokenizedStrategyFile = getTheAbi("TokenizedStrategy");
    const tokenizedStrategyAddress = tokenizedStrategyFile.address;

    const strategy = await deploy("InvestorStrategy", {
        from: deployer,
        args: [investorAddress, asset, "Fathom Investor Strategy 1", tokenizedStrategyAddress],
        log: true,
        gasLimit: "0x1000000",
    });

    const setInvestorStrategyTx = await investor.setStrategy(strategy.address);
    await setInvestorStrategyTx.wait();
};

module.exports.tags = ["InvestorStrategy"];

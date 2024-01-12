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

    const asset = "0xDf29cB40Cb92a1b8E8337F542E3846E185DefF96"; // Real asset address

    console.log("WARN: Ensure You set real asset address!!!");
    console.log("WARN: Ensure BaseStrategy has tokenizedStrategyAddress as constant!!!");
    // console.log("WARN: Ensure InvestorStrategy has Investor address as constant!!!");
    
    // console.log("Sleeping for 60 seconds to give a thought...");
    // await new Promise(r => setTimeout(r, 60000));

    const investorFile = getTheAbi("Investor");
    const investorAddress = investorFile.address;
    const investor = await ethers.getContractAt("Investor", investorAddress);

    const strategy = await deploy("InvestorStrategy", {
        from: deployer,
        args: [investorAddress, asset, "Fathom Investor Strategy 1"],
        log: true,
        gasLimit: "0x1000000",
    });

    const setInvestorStrategyTx = await investor.setStrategy(strategy.address, { gasLimit: "0x1000000" });
    await setInvestorStrategyTx.wait();
};

module.exports.tags = ["InvestorStrategy"];

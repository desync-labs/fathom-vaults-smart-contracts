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

    const factoryFile = getTheAbi("Factory");
    const factoryAddress = factoryFile.address;

    const strategy = await deploy("TokenizedStrategy", {
        from: deployer,
        args: [factoryAddress],
        log: true,
    });
};

module.exports.tags = ["TokenizedStrategy"];

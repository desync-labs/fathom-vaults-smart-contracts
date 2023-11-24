// scripts/initializeVault.js

const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

const getTheAbi = (contract) => {
    try {
        const dir = path.join(__dirname, '..', 'deployments', 'apothem', `${contract}.json`);
        const json = JSON.parse(fs.readFileSync(dir, 'utf8'));
        return json

    } catch (e) {
        console.log(`e`, e)
    }
}

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deployer } = await getNamedAccounts();
    const vaultFile = getTheAbi('FathomVault');
    const tokenFile = getTheAbi('Token');

    const vaultAddress = vaultFile.address;
    const assetAddress = tokenFile.address;

    const vault = await ethers.getContractAt("FathomVault", vaultAddress);
    const asset = await ethers.getContractAt("Token", assetAddress);

    const [owner, addr1, addr2] = await ethers.getSigners();

    // const vault = new ethers.Contract(
    //     vaultAddress,
    //     vaultFile.abi,
    //     deployer,
    // )

    // const asset = new ethers.Contract(
    //     assetAddress,
    //     tokenFile.abi,
    //     deployer,
    // )

    //   const vault = await ethers.getContractAt('FathomVault', vaultAddress);
    //   const asset = await ethers.getContractAt('Token', assetAddress);

    const amount = ethers.parseUnits("1000000", 18)
    const withdrawAmount = ethers.parseUnits("10", 18)
    const redeemAmount = ethers.parseUnits("10", 18)

    // Initialization logic
    console.log("Initializing vault...");
    const mintTx = await asset.connect(owner).mint("0x0Eb7DEE6e18Cce8fE839E986502d95d47dC0ADa3", amount, { gasLimit: "0x1000000" });
    await mintTx.wait(); // Wait for the transaction to be confirmed
    // const approveTx = await asset.connect(owner).approve(vault.target, amount, { gasLimit: "0x1000000" });
    // await approveTx.wait(); // Wait for the transaction to be confirmed
    // const setDepositLimitTx = await vault.connect(owner).setDepositLimit(amount, { gasLimit: "0x1000000" });
    // await setDepositLimitTx.wait(); // Wait for the transaction to be confirmed

    // // Simulate a deposit
    // console.log("Depositing...");
    // const depositTx = await vault.connect(owner).deposit(amount, owner.address, { gasLimit: "0x1000000" });
    // await depositTx.wait(); // Wait for the transaction to be confirmed

    // // Simulate a withdraw
    // console.log("Withdrawing...");
    // const withdrawTx = await vault.connect(owner).withdraw(withdrawAmount, owner.address, owner.address, 0, [], { gasLimit: "0x1000000" });
    // await withdrawTx.wait();

    // // Simulate a redeem
    // console.log("Redeeming...");
    // const redeemTx = await vault.connect(owner).redeem(redeemAmount, owner.address, owner.address, 0, [], { gasLimit: "0x1000000" });
    // await redeemTx.wait();

    // Additional initialization steps as needed...
};

module.exports.tags = ['Init'];


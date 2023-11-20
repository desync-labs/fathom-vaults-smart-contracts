const {
    time,
    loadFixture,
  } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Vault Contract", function () {   
    
    // We define a fixture to reuse the same setup in every test.
    // We use loadFixture to run this setup once, snapshot that state,
    // and reset Hardhat Network to that snapshot in every test.
    async function deployVault() {
        const vaultName = 'FathomVault';
        const vaultSymbol = 'FTHVT';
        const vaultDecimals = 18;

        const Asset = await ethers.getContractFactory("Token");
        const asset = await Asset.deploy(vaultName, vaultDecimals, { gasLimit: "0x1000000" });

        const assetAddress = asset.target;
        const roleManagerAddress = '0x0db96Eb1dc48554bB0f8203A6dE449B2FcCF51a6';
        const profitMaxUnlockTime = 31536000; // 1 year in seconds
        const strategyManagerAddress = '0x0db96Eb1dc48554bB0f8203A6dE449B2FcCF51a6';
        const [owner, otherAccount] = await ethers.getSigners();
        const Vault = await ethers.getContractFactory("FathomVault");
        const vault = await Vault.deploy(assetAddress, vaultName, vaultSymbol, vaultDecimals, roleManagerAddress, profitMaxUnlockTime, strategyManagerAddress, { gasLimit: "0x1000000" });
        // const vault = await ethers.deployContract("FathomVault", [assetAddress, vaultName, vaultSymbol, vaultDecimals, roleManagerAddress, profitMaxUnlockTime, strategyManagerAddress], { gasLimit: "0x1000000" });

        return { vault, owner, otherAccount };
    }

    it("should revert with invalid recipient", async function () {
        const amount = 1000;
        const { vault, otherAccount } = await loadFixture(deployVault);

        await expect(vault.connect(otherAccount).deposit(amount, vault.target)).to.be.revertedWithCustomError(vault, "ExceedDepositLimit");
        await expect(vault.connect(otherAccount).deposit(amount, ethers.ZeroAddress)).to.be.revertedWithCustomError(vault, "ExceedDepositLimit");
  });

});

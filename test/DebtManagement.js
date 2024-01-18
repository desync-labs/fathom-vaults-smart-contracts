const {
    time,
    loadFixture,
  } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { createStrategy, userDeposit, addDebtToStrategy, addStrategyToVault } = require("./utils/helper");

describe("Debt Management", function () {

    const profitMaxUnlockTime = 31536000; // 1 year in seconds
    
    // We define a fixture to reuse the same setup in every test.
    // We use loadFixture to run this setup once, snapshot that state,
    // and reset Hardhat Network to that snapshot in every test.
    async function deployVault() {
        const vaultName = 'Vault Shares FXD';
        const vaultSymbol = 'vFXD';
        const [owner, otherAccount] = await ethers.getSigners();

        const Asset = await ethers.getContractFactory("Token");
        const assetSymbol = 'FXD';
        const vaultDecimals = 18;
        const asset = await Asset.deploy(assetSymbol, vaultDecimals, { gasLimit: "0x1000000" });

        const assetAddress = asset.target;

        const performanceFee = 100; // 1% of gain
        const protocolFee = 2000; // 20% of total fee

        const Accountant = await ethers.getContractFactory("GenericAccountant");
        const accountant = await Accountant.deploy(performanceFee, owner.address, owner.address, { gasLimit: "0x1000000" });

        const VaultPackage = await ethers.getContractFactory("VaultPackage");
        const vaultPackage = await VaultPackage.deploy({ gasLimit: "0x1000000" });

        const FactoryPackage = await ethers.getContractFactory("FactoryPackage");
        const factoryPackage = await FactoryPackage.deploy({ gasLimit: "0x1000000" });

        const Factory = await ethers.getContractFactory("Factory");
        const factoryProxy = await Factory.deploy(factoryPackage.target, owner.address, "0x", { gasLimit: "0x1000000" });

        const factory = await ethers.getContractAt("FactoryPackage", factoryProxy.target);
        await factory.initialize(vaultPackage.target, owner.address, protocolFee);
        
        await factory.deployVault(
            profitMaxUnlockTime,
            assetAddress,
            vaultName,
            vaultSymbol,
            accountant.target,
            owner.address
        );
        const vaults = await factory.getVaults();
        console.log("Existing Vaults = ", vaults);
        const vaultsCopy = [...vaults];
        const vaultAddress = vaultsCopy.pop();
        const vault = await ethers.getContractAt("VaultPackage", vaultAddress);
        console.log("The Last Vault Address = ", vaultAddress);

        return { vault, owner, otherAccount, asset };
    }

    it("should update max debt with debt value", async function () {
        const { vault, owner } = await loadFixture(deployVault);
        const amount = 1000;
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime);
        const strategyParams = await addStrategyToVault(owner, strategy, vault);
        await vault.updateMaxDebtForStrategy(strategy.target, amount);

        const strategyInfo = await vault.strategies(strategy.target);

        expect(strategyInfo.maxDebt).to.equal(amount);
    });

    it("should revert update max debt with inactive strategy", async function () {
        const { vault, owner } = await loadFixture(deployVault);
        const amount = 1000;
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime);
    
        await expect(vault.updateMaxDebtForStrategy(strategy.target, amount))
            .to.be.revertedWithCustomError(vault, "InactiveStrategy");
    });

    it("should revert update debt without permission", async function () {
        const { vault, owner, otherAccount } = await loadFixture(deployVault);
        const amount = 1000;
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime);
        const strategyParams = await addStrategyToVault(owner, strategy, vault);
        await vault.updateMaxDebtForStrategy(strategy.target, amount);

        const errorMessage = new RegExp(`AccessControl: account ${otherAccount.address.toLowerCase()} is missing role 0x1893e1a169e79f2fe8aa327b1bceb2fede7a1b76a54824f95ea0e737720954ae`);
    
        await expect(vault.connect(otherAccount).updateDebt(strategy.target, amount))
            .to.be.revertedWith(errorMessage);
    });


    
});

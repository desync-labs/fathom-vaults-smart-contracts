const {
    time,
    loadFixture,
  } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { createStrategy, userDeposit, addDebtToStrategy, addStrategyToVault } = require("../../utils/helper");

describe("Buy Debt", function () {

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
        const asset = await Asset.deploy(assetSymbol, vaultDecimals);

        const assetAddress = asset.target;

        const performanceFee = 100; // 1% of gain
        const protocolFee = 2000; // 20% of total fee

        const Accountant = await ethers.getContractFactory("GenericAccountant");
        const accountant = await Accountant.deploy(performanceFee, owner.address, owner.address);

        const VaultPackage = await ethers.getContractFactory("VaultPackage");
        const vaultPackage = await VaultPackage.deploy();

        const FactoryPackage = await ethers.getContractFactory("FactoryPackage");
        const factoryPackage = await FactoryPackage.deploy();

        const Factory = await ethers.getContractFactory("Factory");
        const factoryProxy = await Factory.deploy(factoryPackage.target, owner.address, "0x");

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

        return { vault, owner, otherAccount, asset, factory };
    }

    it("should revert buy debt if strategy not active", async function () {
        const { vault, owner, asset, factory } = await loadFixture(deployVault);
        const amount = 1000;
        await vault.setDepositLimit(amount);
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime, factory.target);
        await userDeposit(owner, vault, asset, amount);

        // Approve vault to pull funds.
        await asset.mint(owner.address, amount);
        await asset.connect(owner).approve(vault.target, amount);
    
        await expect(vault.connect(owner).buyDebt(strategy.target, amount))
            .to.be.revertedWithCustomError(vault, "InactiveStrategy");
    });

    it("should revert buy debt with no debt", async function () {
        const { vault, owner, asset, factory } = await loadFixture(deployVault);
        const amount = 1000;
        await vault.setDepositLimit(amount);
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime, factory.target);
        await vault.connect(owner).addStrategy(strategy.target);
        await userDeposit(owner, vault, asset, amount);
    
        await asset.mint(owner.address, amount);
        await asset.connect(owner).approve(vault.target, amount);
    
        await expect(vault.connect(owner).buyDebt(strategy.target, amount))
            .to.be.revertedWithCustomError(vault, "ZeroValue");
    });

    it("should revert buy debt with zero amount", async function () {
        const { vault, owner, asset, factory } = await loadFixture(deployVault);
        const amount = 1000;
        const maxDebt = 10000;
        const debt = 100;
        await vault.setDepositLimit(amount);
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime, factory.target);
        const strategyParams = await addStrategyToVault(owner, strategy, vault);
        await userDeposit(owner, vault, asset, amount);
        await addDebtToStrategy(owner, strategy, vault, maxDebt, debt, strategyParams, vault);
    
        await asset.mint(owner.address, amount);
        await asset.connect(owner).approve(vault.target, amount);
    
        await expect(vault.connect(owner).buyDebt(strategy.target, 0))
            .to.be.revertedWithCustomError(vault, "ZeroValue");
    });
    
    it("should withdraw current debt when buying more than available", async function () {
        const { vault, owner, asset, factory } = await loadFixture(deployVault);
        const amount = 1000;
        const maxDebt = 10000;
        const debt = 100;
        await vault.setDepositLimit(amount);
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime, factory.target);
        const strategyParams = await addStrategyToVault(owner, strategy, vault);
        await userDeposit(owner, vault, asset, amount);
        await addDebtToStrategy(owner, strategy, vault, maxDebt, debt, strategyParams, vault);
    
        await asset.mint(owner.address, amount);
        await asset.connect(owner).approve(vault.target, amount);
    
        const beforeBalance = await asset.balanceOf(owner.address);
        const beforeShares = await strategy.balanceOf(owner.address);

        await expect(vault.connect(owner).buyDebt(strategy.target, amount * 2))
            .to.emit(vault, 'DebtUpdated')
            .withArgs(strategy.target, debt, 0);

        // Assert state changes
        expect(await vault.totalIdle()).to.equal(amount);
        expect(await vault.totalDebt()).to.equal(0);
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));
        const strategyInfo = await vault.strategies(strategy.target);
        expect(strategyInfo.currentDebt).to.equal(0);

        // Assert asset and share balance changes
        const afterBalance = await asset.balanceOf(owner.address);
        const afterShares = await strategy.balanceOf(owner.address);
        expect(afterBalance).to.equal(beforeBalance - BigInt(debt));
        expect(afterShares).to.equal(beforeShares + BigInt(debt));
    });

    it("should buy full debt", async function () {
        const { vault, owner, asset, factory } = await loadFixture(deployVault);
        const amount = 1000;
        const maxDebt = 10000;
        const debt = 100;
        await vault.setDepositLimit(amount);
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime, factory.target);
        const strategyParams = await addStrategyToVault(owner, strategy, vault);
        await userDeposit(owner, vault, asset, amount);
        await addDebtToStrategy(owner, strategy, vault, maxDebt, debt, strategyParams, vault);

        const toBuy = amount / 2;
    
        await asset.mint(owner.address, amount);
        await asset.connect(owner).approve(vault.target, amount);
    
        const beforeBalance = await asset.balanceOf(owner.address);
        const beforeShares = await strategy.balanceOf(owner.address);
    
        // Check if the DebtUpdated event was emitted correctly
        await expect(vault.connect(owner).buyDebt(strategy.target, amount))
            .to.emit(vault, 'DebtUpdated')
            .withArgs(strategy.target, debt, 0);
    
        // Assert state changes
        expect(await vault.totalIdle()).to.equal(amount);
        expect(await vault.totalDebt()).to.equal(0);
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));
        const strategyInfo = await vault.strategies(strategy.target);
        expect(strategyInfo.currentDebt).to.equal(0);
    
        // Assert asset and share balance changes
        const afterBalance = await asset.balanceOf(owner.address);
        const afterShares = await strategy.balanceOf(owner.address);
        expect(afterBalance).to.equal(beforeBalance - BigInt(debt));
        expect(afterShares).to.equal(beforeShares + BigInt(debt));
    });    
    
    it("should buy half the debt", async function () {
        const { vault, owner, asset, factory } = await loadFixture(deployVault);
        const amount = 1000;
        const maxDebt = 10000;
        const debt = 100;
        await vault.setDepositLimit(amount);
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime, factory.target);
        const strategyParams = await addStrategyToVault(owner, strategy, vault);
        await userDeposit(owner, vault, asset, amount);
        await addDebtToStrategy(owner, strategy, vault, maxDebt, debt, strategyParams, vault);
    
        const toBuy = debt / 2;
    
        await asset.mint(owner.address, toBuy);
        await asset.connect(owner).approve(vault.target, toBuy);
    
        const beforeBalance = await asset.balanceOf(owner.address);
        const beforeShares = await strategy.balanceOf(owner.address);
    
        // Check if the DebtUpdated event was emitted correctly
        await expect(vault.connect(owner).buyDebt(strategy.target, toBuy))
            .to.emit(vault, 'DebtUpdated')
            .withArgs(strategy.target, debt, debt - toBuy);
    
        // Assert state changes
        expect(await vault.totalIdle()).to.equal(amount - toBuy);
        expect(await vault.totalDebt()).to.equal(debt - toBuy);
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));
        const strategyInfo = await vault.strategies(strategy.target);
        expect(strategyInfo.currentDebt).to.equal(debt - toBuy);
    
        // Assert asset and share balance changes
        const afterBalance = await asset.balanceOf(owner.address);
        const afterShares = await strategy.balanceOf(owner.address);
        expect(afterBalance).to.equal(beforeBalance - BigInt(toBuy));
        expect(afterShares).to.equal(beforeShares + BigInt(toBuy));
    });    
});

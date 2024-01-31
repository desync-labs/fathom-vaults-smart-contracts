const {
    time,
    loadFixture,
  } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { createStrategy, userDeposit, addDebtToStrategy, addStrategyToVault } = require("../../utils/helper");

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

    it("should revert if strategy max debt is less than new debt", async function () {
        const { vault, owner } = await loadFixture(deployVault);
        const amount = 1000;
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime);
        await addStrategyToVault(owner, strategy, vault);
    
        await vault.connect(owner).updateMaxDebtForStrategy(strategy.target, amount);
    
        await expect(vault.connect(owner).updateDebt(strategy.target, amount + 1))
            .to.be.revertedWithCustomError(vault, "DebtHigherThanMaxDebt");
    });
    
    it("should update debt when current debt is less than new debt", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vault.setDepositLimit(amount);
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime);
        const strategyParams = await addStrategyToVault(owner, strategy, vault);
        await userDeposit(owner, vault, asset, amount);

        const currentDebt = strategyParams.currentDebt;
        const difference = BigInt(amount) - currentDebt;
        const initialIdle = await vault.totalIdle();
        const initialDebt = await vault.totalDebt();
        const vaultBalanceBefore = await asset.balanceOf(vault.target);
    
        await vault.connect(owner).updateMaxDebtForStrategy(strategy.target, amount);
        
        await asset.mint(owner.address, amount);
        await asset.connect(owner).approve(vault.target, amount);
        
        await expect(vault.connect(owner).updateDebt(strategy.target, amount))
            .to.emit(vault, 'DebtUpdated')
            .withArgs(strategy.target, currentDebt, amount);

        const strategyInfo = await vault.strategies(strategy.target);
        expect(strategyInfo.currentDebt).to.equal(amount);
        const strategybalance = await asset.balanceOf(strategy.target);
        expect(strategybalance).to.equal(amount);
        const vaultBalanceAfter = await asset.balanceOf(vault.target);
        expect(vaultBalanceAfter).to.equal(vaultBalanceBefore - BigInt(amount));
        expect(await vault.totalIdle()).to.equal(initialIdle - difference);
        expect(await vault.totalDebt()).to.equal(initialDebt + difference);
    });

    it("should revert if new debt equals current debt", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        const maxDebt = 10000;
        const debt = 100;
        await vault.setDepositLimit(amount);
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime);
        const strategyParams = await addStrategyToVault(owner, strategy, vault);
        await userDeposit(owner, vault, asset, amount);
        await addDebtToStrategy(owner, strategy, vault, maxDebt, debt, strategyParams, vault);
    
        await expect(vault.connect(owner).updateDebt(strategy.target, debt))
            .to.be.revertedWithCustomError(vault, "DebtDidntChange");
    });
    
    it("should revert if current debt is greater than new debt and zero withdrawable", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        const currentDebt = amount;
        const maxDebt = 10000;
        const newDebt = 100;
        const DAYS_IN_SECONDS = 86400;
        await vault.setDepositLimit(amount);

        const LockedStrategy = await ethers.getContractFactory("LockedStrategy");
        const lockedStrategy = await LockedStrategy.deploy(vault.target, await vault.asset(), { gasLimit: "0x1000000" });
        const strategyParams = await addStrategyToVault(owner, lockedStrategy, vault);
        await userDeposit(owner, vault, asset, amount);    
        await addDebtToStrategy(owner, lockedStrategy, vault, maxDebt, amount, strategyParams, vault);

        // lock funds to set withdrawable to zero
        lockedStrategy.setLockedFunds(currentDebt, DAYS_IN_SECONDS, { gasLimit: "0x1000000" })

        // reduce debt in strategy
        await vault.connect(owner).updateMaxDebtForStrategy(lockedStrategy.target, newDebt);
    
        await expect(vault.connect(owner).updateDebt(lockedStrategy.target, newDebt))
            .to.be.revertedWithCustomError(vault, "ZeroValue");
    });
    
    it("should revert if current debt is greater than new debt and strategy has losses", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        const currentDebt = amount;
        const maxDebt = 10000;
        const newDebt = 100;
        const DAYS_IN_SECONDS = 86400;
        const loss = 100; // 10% loss
        await vault.setDepositLimit(amount);

        const LossyStrategy = await ethers.getContractFactory("LossyStrategy");
        const lossyStrategy = await LossyStrategy.deploy(await vault.asset(), "Lossy Strategy", owner.address, owner.address, vault.target, profitMaxUnlockTime, { gasLimit: "0x1000000" });
        const strategyParams = await addStrategyToVault(owner, lossyStrategy, vault);
        await userDeposit(owner, vault, asset, amount);    
        await addDebtToStrategy(owner, lossyStrategy, vault, maxDebt, amount, strategyParams, vault);

        await lossyStrategy.setLoss(owner.address, loss, { gasLimit: "0x1000000" });
    
        await expect(vault.connect(owner).updateDebt(lossyStrategy, newDebt))
            .to.be.revertedWithCustomError(vault, "StrategyHasUnrealisedLosses");
    });

    it("should update debt when current debt is greater than new debt and there's insufficient withdrawable", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        const currentDebt = amount;
        const lockedDebt = currentDebt / 2;
        const maxDebt = 10000;
        const newDebt = 100;
        const difference = currentDebt - lockedDebt; // maximum we can withdraw
        const DAYS_IN_SECONDS = 86400;
        await vault.setDepositLimit(amount);
        await userDeposit(owner, vault, asset, amount);
        const vaultBalanceBefore = await asset.balanceOf(vault.target);

        const LockedStrategy = await ethers.getContractFactory("LockedStrategy");
        const lockedStrategy = await LockedStrategy.deploy(vault.target, await vault.asset(), { gasLimit: "0x1000000" });
        const strategyParams = await addStrategyToVault(owner, lockedStrategy, vault); 
        await addDebtToStrategy(owner, lockedStrategy, vault, maxDebt, currentDebt, strategyParams, vault);

        // reduce debt in strategy
        await vault.connect(owner).updateMaxDebtForStrategy(lockedStrategy, newDebt);
        // lock portion of funds to reduce withdrawable
        lockedStrategy.setLockedFunds(lockedDebt, DAYS_IN_SECONDS, { gasLimit: "0x1000000" })
        const initialIdle = await vault.totalIdle();
        const initialDebt = await vault.totalDebt();
    
        await expect(vault.connect(owner).updateDebt(lockedStrategy.target, newDebt))
            .to.emit(vault, 'DebtUpdated')
            .withArgs(lockedStrategy.target, currentDebt, lockedDebt);

        const strategyInfo = await vault.strategies(lockedStrategy);
        expect(strategyInfo.currentDebt).to.equal(lockedDebt);
        const strategybalance = await asset.balanceOf(lockedStrategy);
        expect(strategybalance).to.equal(lockedDebt);
        const vaultBalanceAfter = await asset.balanceOf(vault.target);
        expect(vaultBalanceAfter).to.equal(vaultBalanceBefore - BigInt(lockedDebt));
        expect(await vault.totalIdle()).to.equal(initialIdle + BigInt(difference));
        expect(await vault.totalDebt()).to.equal(initialDebt - BigInt(difference));
    });
    
    it("should update debt when current debt is greater than new debt and there's sufficient withdrawable", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        const currentDebt = amount;
        const maxDebt = 10000;
        const newDebt = 100;
        const difference = currentDebt - newDebt; // maximum we can withdraw
        await vault.setDepositLimit(amount);
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime);
        const strategyParams = await addStrategyToVault(owner, strategy, vault);
        await userDeposit(owner, vault, asset, amount);
        const vaultBalanceBefore = await asset.balanceOf(vault.target);

        await addDebtToStrategy(owner, strategy, vault, maxDebt, currentDebt, strategyParams, vault);        
        const initialIdle = await vault.totalIdle();
        const initialDebt = await vault.totalDebt();
        // reduce debt in strategy
        await vault.connect(owner).updateMaxDebtForStrategy(strategy, newDebt);
    
        await expect(vault.connect(owner).updateDebt(strategy.target, newDebt))
            .to.emit(vault, 'DebtUpdated')
            .withArgs(strategy.target, currentDebt, newDebt);

        const strategyInfo = await vault.strategies(strategy);
        expect(strategyInfo.currentDebt).to.equal(newDebt);
        const strategybalance = await asset.balanceOf(strategy);
        expect(strategybalance).to.equal(newDebt);
        const vaultBalanceAfter = await asset.balanceOf(vault.target);
        expect(vaultBalanceAfter).to.equal(vaultBalanceBefore - BigInt(newDebt));
        expect(await vault.totalIdle()).to.equal(initialIdle + BigInt(difference));
        expect(await vault.totalDebt()).to.equal(initialDebt - BigInt(difference));
    });
    
    it("should update debt when new debt is greater than max desired debt", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);    
        const maxDebt = 10000;
        const maxDesiredDebt = maxDebt / 2;
        const currentDebt = 1000;
        const difference = maxDesiredDebt - currentDebt; // maximum we can withdraw
        await vault.setDepositLimit(maxDebt);
        const strategy = await createStrategy(owner, vault, profitMaxUnlockTime);
        const strategyParams = await addStrategyToVault(owner, strategy, vault);
        
        await userDeposit(owner, vault, asset, maxDesiredDebt);
        const vaultBalanceBefore = await asset.balanceOf(vault.target);
        
        await addDebtToStrategy(owner, strategy, vault, maxDebt, currentDebt, strategyParams, vault);
        const initialIdle = await vault.totalIdle();
        const initialDebt = await vault.totalDebt();
    
        await vault.updateMaxDebtForStrategy(strategy, maxDebt);
        strategy.setMaxDebt(maxDesiredDebt, { gasLimit: "0x1000000" });
    
        await expect(vault.updateDebt(strategy.target, maxDebt))
            .to.emit(vault, 'DebtUpdated')
            .withArgs(strategy.target, currentDebt, maxDesiredDebt);

        const strategyInfo = await vault.strategies(strategy);
        expect(strategyInfo.currentDebt).to.equal(maxDesiredDebt);
        const strategybalance = await asset.balanceOf(strategy);
        expect(strategybalance).to.equal(maxDesiredDebt);
        const vaultBalanceAfter = await asset.balanceOf(vault.target);
        expect(vaultBalanceAfter).to.equal(vaultBalanceBefore - BigInt(maxDesiredDebt));
        expect(await vault.totalIdle()).to.equal(initialIdle - BigInt(difference));
        expect(await vault.totalDebt()).to.equal(initialDebt + BigInt(difference));
    });

    it("should set minimum total idle", async function () {
        const { vault, owner } = await loadFixture(deployVault);
        const minimumTotalIdle = ethers.parseUnits("1", 21); // Replace with your minimum total idle value
    
        const tx = await vault.setMinimumTotalIdle(minimumTotalIdle);
        
        await expect(vault.setMinimumTotalIdle(minimumTotalIdle))
            .to.emit(vault, 'UpdatedMinimumTotalIdle')
            .withArgs(minimumTotalIdle);
        
        expect(await vault.minimumTotalIdle()).to.equal(minimumTotalIdle);
    });
    
    it("should revert when setting minimum total idle without permission", async function () {
        const { vault, otherAccount } = await loadFixture(deployVault);
        const minimumTotalIdle = ethers.parseUnits("1", 21); // Replace with your minimum total idle value

        const errorMessage = new RegExp(`AccessControl: account ${otherAccount.address.toLowerCase()} is missing role 0x0000000000000000000000000000000000000000000000000000000000000000`);
    
        await expect(vault.connect(otherAccount).setMinimumTotalIdle(minimumTotalIdle))
            .to.be.revertedWith(errorMessage);
    });
    
    
});

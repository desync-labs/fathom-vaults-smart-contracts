const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { createVault, userDeposit, checkVaultEmpty } = require("../utils/helper"); // Update with actual helper functions
const { check } = require("prettier");

// We define a fixture to reuse the same setup in every test.
// We use loadFixture to run this setup once, snapshot that state,
// and reset Hardhat Network to that snapshot in every test.
async function deployVault() {
    const profitMaxUnlockTime = 30; // 1 year in seconds

    const vaultName = 'Vault Shares FXD';
    const vaultSymbol = 'vFXD';
    const [owner, otherAccount, account3, account4, account5] = await ethers.getSigners();

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
    await factory.initialize(vaultPackage.target, account3.address, protocolFee);

    const Investor = await ethers.getContractFactory("Investor");
    const investor = await Investor.deploy({ gasLimit: "0x1000000" });

    const TokenizedStrategy = await ethers.getContractFactory("TokenizedStrategy");
    const tokenizedStrategy = await TokenizedStrategy.deploy(factoryProxy.target);
    
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

    return { vault, owner, otherAccount, account3, account4, account5, asset, investor, profitMaxUnlockTime, factory, tokenizedStrategy };
}

describe("Vault Deposit and Withdraw", function () {

    it("Should deposit and withdraw", async function () {
        const { vault, asset, owner } = await loadFixture(deployVault);
        const amount = 1000;
        const halfAmount = amount / 2;
        const quarterAmount = halfAmount / 2;

        await asset.mint(owner.address, amount);
        await asset.approve(vault.target, amount);
        await vault.setDepositLimit(quarterAmount);
        await vault.deposit(quarterAmount, owner.address);

        expect(await vault.totalSupply()).to.equal(BigInt(quarterAmount));
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(quarterAmount));
        expect(await vault.totalIdle()).to.equal(BigInt(quarterAmount));
        expect(await vault.totalDebt()).to.equal(BigInt(0));
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));

        // set deposit limit to halfAmount and max deposit to test deposit limit
        await vault.setDepositLimit(halfAmount);
    
        await expect(vault.deposit(amount, owner.address))
            .to.be.revertedWithCustomError(vault, "ExceedDepositLimit");

        await vault.deposit(quarterAmount, owner.address);

        expect(await vault.totalSupply()).to.equal(BigInt(halfAmount));
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(halfAmount));
        expect(await vault.totalIdle()).to.equal(BigInt(halfAmount));
        expect(await vault.totalDebt()).to.equal(BigInt(0));
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));

        // raise deposit limit to amount and allow full deposit through to test deposit limit change
        await vault.setDepositLimit(amount);

        // deposit again to test behavior when vault has existing shares
        await vault.deposit(halfAmount, owner.address)

        expect(await vault.totalSupply()).to.equal(BigInt(amount));
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(amount));
        expect(await vault.totalIdle()).to.equal(BigInt(amount));
        expect(await vault.totalDebt()).to.equal(BigInt(0));
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));

        await vault.withdraw(halfAmount, owner.address, owner.address, 0 , []);

        expect(await vault.totalSupply()).to.equal(BigInt(halfAmount));
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(halfAmount));
        expect(await vault.totalIdle()).to.equal(BigInt(halfAmount));
        expect(await vault.totalDebt()).to.equal(BigInt(0));
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));

        await vault.withdraw(halfAmount, owner.address, owner.address, 0, []);

        await checkVaultEmpty(vault);
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(0));
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));
    });

    it("Should handle delegated deposit and withdraw", async function () {
        const { vault, asset, owner, otherAccount, account3, account4, account5 } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);
        const balance = await asset.balanceOf(owner.address);

        // make sure we have some assets to play with
        expect(balance).to.be.gt(0);

        // 1. Deposit from owner and send shares to otherAccount
        await vault.setDepositLimit(amount);
        await asset.approve(vault.target, asset.balanceOf(owner.address));
        await vault.deposit(asset.balanceOf(owner.address), otherAccount.address);

        // owner no longer has any assets
        expect(await asset.balanceOf(owner.address)).to.equal(BigInt(0));
        // owner does not have any vault shares
        expect(await vault.balanceOf(owner.address)).to.equal(BigInt(0));
        // otherAccount has been issued the vault shares
        expect(await vault.balanceOf(otherAccount.address)).to.equal(balance);

        // 2. Withdraw from otherAccount to account3
        await vault.connect(otherAccount).withdraw(vault.balanceOf(otherAccount.address), account3.address, otherAccount.address, 0, []);

        // otherAccount no longer has any shares
        expect(await vault.balanceOf(otherAccount.address)).to.equal(BigInt(0));
        // otherAccount did not receive any assets
        expect(await asset.balanceOf(otherAccount.address)).to.equal(BigInt(0));
        // account3 has the assets
        expect(await asset.balanceOf(account3.address)).to.equal(balance);

        // 3. Deposit from account2 and send shares to account4
        await asset.connect(account3).approve(vault.target, asset.balanceOf(account3.address));
        await vault.connect(account3).deposit(asset.balanceOf(account3.address), account4.address)

        // account3 no longer has any assets
        expect(await asset.balanceOf(account3.address)).to.equal(BigInt(0));
        // account3 does not have any vault shares
        expect(await vault.balanceOf(account3.address)).to.equal(BigInt(0));
        // panda has been issued the vault shares
        expect(await vault.balanceOf(account4.address)).to.equal(balance);

        // 4. Withdraw from account4 to account5
        await vault.connect(account4).withdraw(vault.balanceOf(account4.address), account5.address, account4.address, 0, []);

        // account4 no longer has any shares
        expect(await vault.balanceOf(account4.address)).to.equal(BigInt(0));
        // account4 did not receive any assets
        expect(await asset.balanceOf(account4.address)).to.equal(BigInt(0));
        // account5 has the assets
        expect(await asset.balanceOf(account5.address)).to.equal(balance);
    });
});

describe.only("Vault Deposit and Withdraw with Strategy", function () {
    
    it("Should deposit, setup Investor Strategy, setup Investor, add Strategy to the Vault, send funds from Vault to Strategy, create Profit Reports and withdraw all", async function () {
        const { vault, asset, owner, investor, profitMaxUnlockTime, factory, otherAccount, tokenizedStrategy } = await loadFixture(deployVault);
        const amount = ethers.parseUnits("1000", 18);
        const halfAmount = amount / BigInt(2);
        const quarterAmount = halfAmount / BigInt(2);

        await asset.mint(owner.address, amount);
        await asset.mint(otherAccount.address, amount);
        await asset.approve(vault.target, amount);
        await asset.connect(otherAccount).approve(vault.target, amount);
        await vault.setDepositLimitAndModule(amount, ethers.ZeroAddress);
        await vault.connect(otherAccount).deposit(quarterAmount, otherAccount.address);

        expect(await vault.totalSupply()).to.equal(quarterAmount);
        expect(await asset.balanceOf(vault.target)).to.equal(quarterAmount);
        expect(await vault.balanceOf(otherAccount.address)).to.equal(quarterAmount);
        expect(await vault.totalIdle()).to.equal(quarterAmount);
        expect(await vault.totalDebt()).to.equal(BigInt(0));
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));

        // Setup Strategy
        const InvestorStrategy = await ethers.getContractFactory("InvestorStrategy");
        const investorStrategy = await InvestorStrategy.deploy(investor.target, await vault.asset(), "Investor Strategy", tokenizedStrategy.target);
        const strategy = await ethers.getContractAt("TokenizedStrategy", investorStrategy.target);
        const strategyAsset = await strategy.asset();
        console.log("Strategy Asset = ", strategyAsset);

        expect(await strategy.asset()).to.equal(await vault.asset());

        // Setup Investor
        await asset.approve(investor.target, amount);
        await expect(investor.setStrategy(strategy.target))
            .to.emit(investor, 'StrategyUpdate')
            .withArgs(strategy.target, strategy.target, await vault.asset());
        let blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
        const startDistribution = blockTimestamp + 10;
        const endDistribution = blockTimestamp + 60;
        await expect(investor.setupDistribution(halfAmount, startDistribution, endDistribution))
            .to.emit(investor, 'DistributionSetup')
            .withArgs(halfAmount, startDistribution, endDistribution);
        expect(await investor.rewardsLeft()).to.equal(halfAmount);
        expect(await investor.rewardRate()).to.equal(halfAmount / BigInt(endDistribution - startDistribution));
        

        // Add Strategy to Vault
        await expect(vault.addStrategy(strategy.target))
            .to.emit(vault, 'StrategyChanged')
            .withArgs(strategy.target, 0);
        await expect(vault.updateMaxDebtForStrategy(strategy.target, amount))
            .to.emit(vault, 'UpdatedMaxDebtForStrategy')
            .withArgs(owner.address, strategy.target, amount);

        // Send funds from vault to strategy
        await vault.updateDebt(strategy.target, await vault.totalIdle());
        expect(await vault.totalSupply()).to.equal(quarterAmount);
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(0));
        expect(await asset.balanceOf(strategy.target)).to.equal(quarterAmount);
        expect(await vault.balanceOf(otherAccount.address)).to.equal(quarterAmount);
        expect(await vault.totalIdle()).to.equal(BigInt(0));
        expect(await vault.totalDebt()).to.equal(quarterAmount);
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));
        
        // Simulate time passing
        await time.increase(10);

        // Create first Profit Report
        await strategy.report();
        await vault.processReport(strategy.target);
        blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
        expect(await investor.rewardsLeft()).to.equal(halfAmount - (halfAmount / BigInt(endDistribution - startDistribution)) * BigInt(blockTimestamp - startDistribution - 1));
        expect(await asset.balanceOf(strategy.target)).to.equal(BigInt(quarterAmount) + await investor.distributedRewards());
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(0));
        expect(await vault.balanceOf(otherAccount.address)).to.equal(quarterAmount);
        expect(await vault.totalIdle()).to.equal(BigInt(0));

        // Simulate time passing
        await time.increase(20);

        // Create second Profit Report
        await strategy.report();
        await vault.processReport(strategy.target);
        blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
        expect(await investor.rewardsLeft()).to.equal(halfAmount - (halfAmount / BigInt(endDistribution - startDistribution)) * BigInt(blockTimestamp - startDistribution - 1));
        expect(await asset.balanceOf(strategy.target)).to.equal(BigInt(quarterAmount) + await investor.distributedRewards());
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(0));
        expect(await vault.balanceOf(otherAccount.address)).to.equal(quarterAmount);
        expect(await vault.totalIdle()).to.equal(BigInt(0));

        // Simulate time passing
        await time.increase(18);

        // Create third Profit Report
        await strategy.report();
        await vault.processReport(strategy.target);
        blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
        expect(await investor.rewardsLeft()).to.equal(halfAmount - (halfAmount / BigInt(endDistribution - startDistribution)) * BigInt(blockTimestamp - startDistribution - 1));
        expect(await asset.balanceOf(strategy.target)).to.equal(quarterAmount + await investor.distributedRewards());
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(0));
        expect(await vault.balanceOf(otherAccount.address)).to.equal(quarterAmount);
        expect(await vault.totalIdle()).to.equal(BigInt(0));

        // Simulate time passing
        await time.increase(60 * 60 * 24 * 365);

        // Create fourth Profit Report
        await vault.processReport(strategy.target);
        blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
        expect(await asset.balanceOf(strategy.target)).to.equal(quarterAmount + await investor.distributedRewards());
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(0));
        expect(await vault.balanceOf(otherAccount.address)).to.equal(quarterAmount);
        expect(await vault.totalIdle()).to.equal(BigInt(0));

        // Simulate time passing
        await time.increase(60 * 60 * 24 * 365);

        // Create last Profit Report
        await vault.processReport(strategy.target);
        blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
        expect(await asset.balanceOf(strategy.target)).to.equal(quarterAmount + await investor.distributedRewards());
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(0));
        expect(await vault.balanceOf(otherAccount.address)).to.equal(quarterAmount);
        expect(await vault.totalIdle()).to.equal(BigInt(0));

        // Send funds from strategy back to vault
        await vault.updateDebt(strategy.target, 0);

        // Withdraw all
        let otherAccountShares = await vault.balanceOf(otherAccount.address);
        await vault.connect(otherAccount).redeem(otherAccountShares, otherAccount.address, otherAccount.address, 0, []);
        let pricePerShare = await vault.pricePerShare();
        let totalFees = await vault.balanceOf(await vault.accountant()) + await vault.balanceOf(await factory.feeRecipient());
        let feesShares = totalFees * pricePerShare / ethers.parseUnits("1", await asset.decimals());
        // Adding 2 due to rounding error
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(feesShares) + BigInt(2));
        let otherAccountBalance = otherAccountShares * pricePerShare / ethers.parseUnits("1", await asset.decimals());
        expect(await asset.balanceOf(otherAccount.address)).greaterThan(amount - quarterAmount + otherAccountBalance);
        expect(await vault.balanceOf(otherAccount.address)).to.equal(BigInt(0));
        expect(await vault.totalDebt()).to.equal(BigInt(0));
        expect(await vault.totalIdle()).to.equal(BigInt(feesShares) + BigInt(2));
        expect(await vault.totalSupply()).to.equal(totalFees);
    });
});
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
    const profitMaxUnlockTime = 31536000; // 1 year in seconds

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
    await factory.initialize(vaultPackage.target, owner.address, protocolFee);

    const Investor = await ethers.getContractFactory("Investor");
    const investor = await Investor.deploy({ gasLimit: "0x1000000" });
    
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

    return { vault, owner, otherAccount, account3, account4, account5, asset, investor, profitMaxUnlockTime };
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
    
    it("Should deposit, setup Investor Strategy, setup Investor, add Strategy to the Vault, send funds from Vault to Strategy, create 3 Profit Reports and withdraw all", async function () {
        const { vault, asset, owner, investor, profitMaxUnlockTime } = await loadFixture(deployVault);
        const amount = 1000;
        const halfAmount = amount / 2;
        const quarterAmount = halfAmount / 2;

        await asset.mint(owner.address, amount);
        await asset.approve(vault.target, amount);
        await vault.setDepositLimit(amount);
        await vault.deposit(quarterAmount, owner.address);

        expect(await vault.totalSupply()).to.equal(BigInt(quarterAmount));
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(quarterAmount));
        expect(await vault.balanceOf(owner.address)).to.equal(BigInt(quarterAmount));
        expect(await vault.totalIdle()).to.equal(BigInt(quarterAmount));
        expect(await vault.totalDebt()).to.equal(BigInt(0));
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));

        // Setup Strategy
        const Strategy = await ethers.getContractFactory("InvestorStrategy");    
        const strategy = await Strategy.deploy(investor.target, await vault.asset(), "Investor Strategy", owner.address, owner.address, profitMaxUnlockTime);
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
        expect(await investor.rewardsLeft()).to.equal(BigInt(halfAmount));
        // Simulate time passing
        await time.increase(10);

        // Add Strategy to Vault
        await expect(vault.addStrategy(strategy.target))
            .to.emit(vault, 'StrategyChanged')
            .withArgs(strategy.target, 0);
        await expect(vault.updateMaxDebtForStrategy(strategy.target, amount))
            .to.emit(vault, 'UpdatedMaxDebtForStrategy')
            .withArgs(owner.address, strategy.target, BigInt(amount));

        // Send funds from vault to strategy
        await vault.updateDebt(strategy.target, await vault.totalIdle());
        expect(await vault.totalSupply()).to.equal(BigInt(quarterAmount));
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(0));
        expect(await asset.balanceOf(strategy.target)).to.equal(BigInt(quarterAmount));
        expect(await vault.balanceOf(owner.address)).to.equal(BigInt(quarterAmount));
        expect(await vault.totalIdle()).to.equal(BigInt(0));
        expect(await vault.totalDebt()).to.equal(BigInt(quarterAmount));
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));
    });
});


    // let balanceStrategy = await asset.balanceOf(strategy.target);
    // console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    // let accountantShares = await vault.balanceOf(accountantAddress);
    // console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));

    // console.log("Creating profit for Strategy...");
    // const distributionTx = await investor.processReport({ gasLimit: "0x1000000" });
    // await distributionTx.wait();
    // console.log("Create report for Strategy...");
    // const reportTx = await strategy.report({ gasLimit: "0x1000000" });
    // await reportTx.wait();
    // blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
    // console.log("Block Timestamp = ", blockTimestamp);
    // console.log("Process report for Strategy on Vault...");
    // const processReportTx = await vault.processReport(strategy.target, { gasLimit: "0x1000000" });
    // await processReportTx.wait();
    // let fullProfitUnlockDate = (await vault.fullProfitUnlockDate()).toString();
    // console.log("Full Profit Unlock Date = ", fullProfitUnlockDate);

    // // Sleep for 60 seconds
    // console.log("Sleeping for 60 seconds...");
    // await new Promise(r => setTimeout(r, 60000));

    // console.log("Create second report for Strategy after sleeping...");
    // const reportTx2 = await strategy.report({ gasLimit: "0x1000000" });
    // await reportTx2.wait();
    // blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
    // console.log("Block Timestamp = ", blockTimestamp);
    // console.log("Process second report for Strategy on Vault after sleeping...");
    // const processReportTx2 = await vault.processReport(strategy.target, { gasLimit: "0x1000000" });
    // await processReportTx2.wait();

    // console.log("Updating balances...");
    // balanceInShares = await vault.balanceOf(deployer);
    // console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    // balanceInTokens = await vault.convertToAssets(balanceInShares);
    // console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    // balanceVaultInShares = await vault.balanceOf(vaultAddress);
    // console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    // balanceVaultInTokens = await asset.balanceOf(vaultAddress);
    // console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    // balanceStrategy = await asset.balanceOf(strategy.target);
    // console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    // accountantShares = await vault.balanceOf(accountantAddress);
    // console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));

    // // Sleep for another 60 seconds
    // console.log("Sleeping for 60 seconds...");
    // await new Promise(r => setTimeout(r, 60000));

    // console.log("Create third report for Strategy after sleeping...");
    // const reportTx3 = await strategy.report({ gasLimit: "0x1000000" });
    // await reportTx3.wait();
    // blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
    // console.log("Block Timestamp = ", blockTimestamp);
    // console.log("Process third report for Strategy on Vault after sleeping...");
    // const processReportTx3 = await vault.processReport(strategy.target, { gasLimit: "0x1000000" });
    // await processReportTx3.wait();

    // console.log("Updating balances...");
    // balanceInShares = await vault.balanceOf(deployer);
    // console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    // balanceInTokens = await vault.convertToAssets(balanceInShares);
    // console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    // balanceVaultInShares = await vault.balanceOf(vaultAddress);
    // console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    // balanceVaultInTokens = await asset.balanceOf(vaultAddress);
    // console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    // balanceStrategy = await asset.balanceOf(strategy.target);
    // console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    // accountantShares = await vault.balanceOf(accountantAddress);
    // console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));

    // // Simulate a redeem
    // console.log("Redeeming...");
    // const redeemTx = await vault.redeem(balanceInShares, deployer, deployer, 0, [], { gasLimit: "0x1000000" });
    // await redeemTx.wait();

    // console.log("Updating balances...");
    // balanceInShares = await vault.balanceOf(deployer);
    // console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    // balanceInTokens = await vault.convertToAssets(balanceInShares);
    // console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    // balanceVaultInShares = await vault.balanceOf(vaultAddress);
    // console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    // balanceVaultInTokens = await asset.balanceOf(vaultAddress);
    // console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    // balanceStrategy = await asset.balanceOf(strategy.target);
    // console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    // accountantShares = await vault.balanceOf(accountantAddress);
    // console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));
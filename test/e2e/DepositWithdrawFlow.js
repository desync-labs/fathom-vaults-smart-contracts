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
    const assetType = 1; // 1 for Normal / 2 for Deflationary / 3 for Rebasing
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
        assetType,
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

    const STRATEGY_MANAGER = ethers.keccak256(ethers.toUtf8Bytes("STRATEGY_MANAGER"));
    const REPORTING_MANAGER = ethers.keccak256(ethers.toUtf8Bytes("REPORTING_MANAGER"));
    const DEBT_PURCHASER = ethers.keccak256(ethers.toUtf8Bytes("DEBT_PURCHASER"));

    await vault.grantRole(STRATEGY_MANAGER, owner.address);
    await vault.grantRole(REPORTING_MANAGER, owner.address);
    await vault.grantRole(DEBT_PURCHASER, owner.address);

    return { vault, owner, otherAccount, account3, account4, account5, asset, investor, profitMaxUnlockTime, factory, tokenizedStrategy };
}

async function deployVaultApothem() {
    const profitMaxUnlockTime = 30; // 1 year in seconds

    const vaultName = 'Vault Shares FXD';
    const vaultSymbol = 'vFXD';
    const [owner, account3, account4, account5] = await ethers.getSigners();
    const pKey = ethers.HDNodeWallet.createRandom();
    const otherAccount = new ethers.Wallet(pKey.privateKey, ethers.provider);

    // Ether amount to send
    let amountInEther = '0.1'
    // Create a transaction object
    let tx = {
        to: otherAccount.address,
        // Convert currency unit from ether to wei
        value: ethers.parseEther(amountInEther)
    }
    // Send a transaction
    const sendEthTx = await owner.sendTransaction(tx);
    await sendEthTx.wait(1);

    await ethers.provider.getBalance(otherAccount.address).then((balance) => {
        // convert a currency unit from wei to ether
        const balanceInEth = ethers.formatEther(balance)
        console.log(`balance: ${balanceInEth} ETH`)
    })

    const wxdcApothem = "0x7F9b806eb971Cf2464E64AB80c2C1C85a8502c2a";
    const Asset = await ethers.getContractFactory("Token");
    const asset = await ethers.getContractAt("Token", wxdcApothem);
    const assetAddress = asset.target;
    const assetType = 1; // 1 for Normal / 2 for Deflationary / 3 for Rebasing

    const performanceFee = 100; // 1% of gain
    const protocolFee = 2000; // 20% of total fee

    const Accountant = await ethers.getContractFactory("GenericAccountant");
    const accountant = await Accountant.deploy(performanceFee, owner.address, owner.address);
    await accountant.deploymentTransaction().wait(1);

    const VaultPackage = await ethers.getContractFactory("VaultPackage");
    const vaultPackage = await VaultPackage.deploy();
    await vaultPackage.deploymentTransaction().wait(1);

    const FactoryPackage = await ethers.getContractFactory("FactoryPackage");
    const factoryPackage = await FactoryPackage.deploy();
    await factoryPackage.deploymentTransaction().wait(1);

    const Factory = await ethers.getContractFactory("Factory");
    const factoryProxy = await Factory.deploy(factoryPackage.target, owner.address, "0x");
    await factoryProxy.deploymentTransaction().wait(1);

    const factory = await ethers.getContractAt("FactoryPackage", factoryProxy.target);
    const factoryInitTx = await factory.initialize(vaultPackage.target, owner.address, protocolFee, { gasLimit: "0x1000000" });
    await factoryInitTx.wait();

    const TokenizedStrategy = await ethers.getContractFactory("TokenizedStrategy");
    const tokenizedStrategy = await TokenizedStrategy.deploy(factoryProxy.target);
    await tokenizedStrategy.deploymentTransaction().wait(1);
    
    const deployVaultTx = await factory.deployVault(
        profitMaxUnlockTime,
        assetType,
        assetAddress,
        vaultName,
        vaultSymbol,
        accountant.target,
        owner.address
    );
    await deployVaultTx.wait();
    
    const vaults = await factory.getVaults();
    console.log("Existing Vaults = ", vaults);
    const vaultsCopy = [...vaults];
    const vaultAddress = vaultsCopy.pop();
    const vault = await ethers.getContractAt("VaultPackage", vaultAddress);
    console.log("The Last Vault Address = ", vaultAddress);

    return { vault, owner, otherAccount, account3, account4, account5, asset, profitMaxUnlockTime, factory, tokenizedStrategy };
}

describe.only("Vault Deposit and Withdraw", function () {

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
        // account4 has been issued the vault shares
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

describe("Vault Deposit and Withdraw with Strategy", function () {
    
    it("Should deposit, setup Investor Strategy, setup Investor, add Strategy to the Vault, send funds from Vault to Strategy, create Profit Reports and withdraw all", async function () {
        const { vault, asset, owner, investor, profitMaxUnlockTime, factory, otherAccount, tokenizedStrategy } = await loadFixture(deployVault);
        const amount = ethers.parseUnits("1000", 18);
        const halfAmount = amount / BigInt(2);
        const quarterAmount = halfAmount / BigInt(2);

        await asset.mint(owner.address, amount);
        await asset.mint(otherAccount.address, amount);
        await asset.approve(vault.target, amount);
        await asset.connect(otherAccount).approve(vault.target, amount);
        await vault.setDepositLimit(amount);
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
describe("Aave Strategy", function () {
    
    it("Should deposit, setup Aave Strategy, add Strategy to the Vault, send funds from Vault to Strategy, create Profit Reports and withdraw all", async function () {
        const { vault, asset, owner, tokenizedStrategy, factory, otherAccount } = await deployVaultApothem();
        const lendingPoolAddress = "0x0ba52c1df3dB6FE520Ba137F84a82d0657ca4422";
        console.log("Other Account Address = ", otherAccount.address);
        
        const amount = ethers.parseUnits("1000", 18);
        const halfAmount = amount / BigInt(2);
        const quarterAmount = halfAmount / BigInt(2);

        const mintTx = await asset.mint(owner.address, amount);
        await mintTx.wait();
        const approveTx = await asset.approve(vault.target, amount);
        await approveTx.wait();
        const mintTx2 = await asset.mint(otherAccount.address, amount);
        await mintTx2.wait();
        const approveTx2 = await asset.connect(otherAccount).approve(vault.target, amount);
        await approveTx2.wait();
        const depositLimitTx = await vault.setDepositLimit(amount);
        await depositLimitTx.wait();
        const depositTx = await vault.connect(otherAccount).deposit(amount, otherAccount.address);
        await depositTx.wait();

        expect(await vault.totalSupply()).to.equal(amount);
        expect(await asset.balanceOf(vault.target)).to.equal(amount);
        expect(await vault.balanceOf(otherAccount.address)).to.equal(amount);
        expect(await vault.totalIdle()).to.equal(amount);
        expect(await vault.totalDebt()).to.equal(BigInt(0));
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));          

        const lendingPool = await ethers.getContractAt("IPool", lendingPoolAddress);
        const aTokenAddress = (await lendingPool.getReserveData(asset.target)).aTokenAddress;
        console.log("AToken Address = ", aTokenAddress);
        const aToken = await ethers.getContractAt("IAToken", aTokenAddress);

        // Setup Aave Strategy
        const AaveStrategy = await ethers.getContractFactory("AaveV3Lender");
        const aaveStrategy = await AaveStrategy.deploy(await vault.asset(), "Aave Strategy", tokenizedStrategy.target, lendingPoolAddress);
        await aaveStrategy.deploymentTransaction().wait(1);
        const strategy = await ethers.getContractAt("TokenizedStrategy", aaveStrategy.target);
        const strategyAsset = await strategy.asset();
        console.log("Strategy Asset = ", strategyAsset);

        expect(await strategy.asset()).to.equal(await vault.asset());

        // Add Strategy to Vault
        const addStrategyTx = await vault.addStrategy(strategy.target);
        await addStrategyTx.wait();
        await expect(addStrategyTx)
            .to.emit(vault, 'StrategyChanged')
            .withArgs(strategy.target, 0);
        const updateMaxDebtForStrategyTx = await vault.updateMaxDebtForStrategy(strategy.target, amount);
        await updateMaxDebtForStrategyTx.wait();
        await expect(updateMaxDebtForStrategyTx)
            .to.emit(vault, 'UpdatedMaxDebtForStrategy')
            .withArgs(owner.address, strategy.target, amount);

        // Send funds from vault to strategy
        const updateDebtTx = await vault.updateDebt(strategy.target, await vault.totalIdle());
        await updateDebtTx.wait();

        expect(await vault.totalSupply()).to.equal(amount);
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(0));
        expect(await aToken.balanceOf(strategy.target)).greaterThan(BigInt(0));
        expect(await vault.balanceOf(otherAccount.address)).to.equal(amount);
        expect(await vault.totalIdle()).to.equal(BigInt(0));
        expect(await vault.totalDebt()).to.equal(amount);
        expect(await vault.pricePerShare()).to.equal(ethers.parseUnits("1", await asset.decimals()));

        // Create first Profit Report for Aave Strategy
        let gain = 100;
        console.log("Creating profit for Aave Strategy...");
        const transferTx = await asset.transfer(strategy.target, gain);
        await transferTx.wait();
        console.log("Creating first report for Aave Strategy...");
        const reportTx = await strategy.report();
        await reportTx.wait();
        console.log("Processing first report for Aave Strategy on Vault...");
        const processReportTx = await vault.processReport(strategy.target, { gasLimit: "0x1000000" });
        await processReportTx.wait();

        // Simulate time passing
        await new Promise(r => setTimeout(r, 15000));

        // Create second Profit Report for Aave Strategy
        console.log("Creating second report for Aave Strategy...");
        const reportTx2 = await strategy.report();
        await reportTx2.wait();
        console.log("Processing second report for Aave Strategy on Vault...");
        const processReportTx2 = await vault.processReport(strategy.target, { gasLimit: "0x1000000" });
        await processReportTx2.wait();

        expect(await aToken.balanceOf(strategy.target)).to.equal(BigInt(amount) + BigInt(gain));
        expect(await asset.balanceOf(vault.target)).to.equal(BigInt(0));
        expect(await vault.balanceOf(otherAccount.address)).to.equal(amount);
        expect(await vault.totalIdle()).to.equal(BigInt(0));

        // Withdraw all
        let accountShares = await vault.balanceOf(otherAccount.address);  
        const redeemTx = await vault.connect(otherAccount).redeem(accountShares, otherAccount.address, otherAccount.address, 0, []);
        await redeemTx.wait();
        let pricePerShare = await vault.pricePerShare();
        let totalFees = await vault.balanceOf(await vault.accountant()) + await vault.balanceOf(await factory.feeRecipient());
        let fees = totalFees * pricePerShare / ethers.parseUnits("1", await asset.decimals());
        expect(await aToken.balanceOf(strategy.target)).greaterThan(BigInt(fees));
        expect(await asset.balanceOf(otherAccount.address)).to.be.at.most(amount + (BigInt(gain) - (BigInt(fees))));
        expect(await vault.balanceOf(otherAccount.address)).to.equal(BigInt(0));
        expect(await vault.totalDebt()).to.be.at.least(fees);
        expect(await vault.totalIdle()).to.equal(BigInt(0));
    }).timeout(1000000);
});
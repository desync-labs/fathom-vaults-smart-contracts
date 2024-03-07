const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { ethers } = require("hardhat");
const { expect } = require("chai");

// Fixture for deploying InvestorStrategy with all dependencies
async function deployInvestorStrategyFixture() {
    const profitMaxUnlockTime = 30;
    const minAmountToSell = 1000;
    const amount = "1000";

    const vaultName = 'Vault Shares FXD';
    const vaultSymbol = 'vFXD';
    const [deployer, manager, otherAccount] = await ethers.getSigners();

    // Deploy MockERC20 as the asset
    const Asset = await ethers.getContractFactory("Token");
    const assetSymbol = 'FXD';
    const vaultDecimals = 18;
    const asset = await Asset.deploy(assetSymbol, vaultDecimals, { gasLimit: "0x1000000" });
    const assetType = 1; // 1 for Normal / 2 for Deflationary / 3 for Rebasing

    await asset.mint(deployer.address, ethers.parseEther(amount));

    const assetAddress = asset.target;

    const performanceFee = 100; // 1% of gain
    const protocolFee = 2000; // 20% of total fee

    const Accountant = await ethers.getContractFactory("GenericAccountant");
    const accountant = await Accountant.deploy(performanceFee, deployer.address, deployer.address, { gasLimit: "0x1000000" });

    const VaultPackage = await ethers.getContractFactory("VaultPackage");
    const vaultPackage = await VaultPackage.deploy({ gasLimit: "0x1000000" });

    const FactoryPackage = await ethers.getContractFactory("FactoryPackage");
    const factoryPackage = await FactoryPackage.deploy({ gasLimit: "0x1000000" });

    const Factory = await ethers.getContractFactory("Factory");
    const factoryProxy = await Factory.deploy(factoryPackage.target, deployer.address, "0x", { gasLimit: "0x1000000" });

    const factory = await ethers.getContractAt("FactoryPackage", factoryProxy.target);
    await factory.initialize(vaultPackage.target, otherAccount.address, protocolFee);

    // Deploy TokenizedStrategy
    const TokenizedStrategy = await ethers.getContractFactory("TokenizedStrategy");
    const tokenizedStrategy = await TokenizedStrategy.deploy(factoryProxy.target);
    
    await factory.deployVault(
        profitMaxUnlockTime,
        assetType,
        assetAddress,
        vaultName,
        vaultSymbol,
        accountant.target,
        deployer.address
    );
    const vaults = await factory.getVaults();
    const vaultsCopy = [...vaults];
    const vaultAddress = vaultsCopy.pop();
    const vault = await ethers.getContractAt("VaultPackage", vaultAddress);

    const STRATEGY_MANAGER = ethers.keccak256(ethers.toUtf8Bytes("STRATEGY_MANAGER"));
    const REPORTING_MANAGER = ethers.keccak256(ethers.toUtf8Bytes("REPORTING_MANAGER"));
    const DEBT_PURCHASER = ethers.keccak256(ethers.toUtf8Bytes("DEBT_PURCHASER"));

    await vault.grantRole(STRATEGY_MANAGER, deployer.address);
    await vault.grantRole(REPORTING_MANAGER, deployer.address);
    await vault.grantRole(DEBT_PURCHASER, deployer.address);

    const Investor = await ethers.getContractFactory("Investor");
    const investor = await Investor.deploy({ gasLimit: "0x1000000" });

    // Deploy InvestorStrategy
    const InvestorStrategy = await ethers.getContractFactory("InvestorStrategy");
    const investorStrategy = await InvestorStrategy.deploy(
        investor.target,
        asset.target,
        "Investor Strategy",
        tokenizedStrategy.target
    );

    const strategy = await ethers.getContractAt("TokenizedStrategy", investorStrategy.target);

    // Setup Investor
    await asset.approve(investor.target, amount);
    await expect(investor.setStrategy(strategy.target))
        .to.emit(investor, 'StrategyUpdate')
        .withArgs(strategy.target, strategy.target, await vault.asset());
    let blockTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
    const startDistribution = blockTimestamp + 10;
    const endDistribution = blockTimestamp + 60;
    await expect(investor.setupDistribution(amount, startDistribution, endDistribution))
        .to.emit(investor, 'DistributionSetup')
        .withArgs(amount, startDistribution, endDistribution);
    expect(await investor.rewardsLeft()).to.equal(amount);
    expect(await investor.rewardRate()).to.equal(amount / (endDistribution - startDistribution));

    // Add Strategy to Vault
    await expect(vault.addStrategy(strategy.target))
        .to.emit(vault, 'StrategyChanged')
        .withArgs(strategy.target, 0);
    await expect(vault.updateMaxDebtForStrategy(strategy.target, amount))
        .to.emit(vault, 'UpdatedMaxDebtForStrategy')
        .withArgs(deployer.address, strategy.target, amount);

    return { vault, strategy, investor, asset, deployer, manager, otherAccount };
}

describe("InvestorStrategy tests", function () {

    describe("InvestorStrategy init tests", function () {
        it("Initializes with correct parameters", async function () {
            const { asset, strategy } = await loadFixture(deployInvestorStrategyFixture);
            expect(await strategy.asset()).to.equal(asset.target);
        });
    });

    describe("_harvestAndReport()", function () {
        it("Correctly reports total assets", async function () {
            const { strategy, asset, investor } = await loadFixture(deployInvestorStrategyFixture);

            // Simulate time passing
            const elapsedTime = 10;
            await time.increase(elapsedTime);
    
            await strategy.report();

            const distributedRewards = await investor.distributedRewards();
            const totalAssets = await strategy.totalAssets();
            expect(totalAssets).to.equal(distributedRewards);
        });

        it("Reverts when called by an unauthorized account", async function () {
            const { strategy, asset, manager, otherAccount } = await loadFixture(deployInvestorStrategyFixture);
    
            await expect(strategy.connect(otherAccount).report())
                .to.be.revertedWith("!keeper"); // Adjust the revert message based on your implementation
        });
    });

    describe("availableDepositLimit()", function () {
        it("Returns max uint256 when the contract holds no asset tokens", async function () {
            const { strategy, deployer } = await loadFixture(deployInvestorStrategyFixture);
            
            const InvestorStrategy = await ethers.getContractAt("InvestorStrategy", strategy.target);
            const availableLimit = await InvestorStrategy.availableDepositLimit(deployer.address);
            expect(availableLimit).to.equal(ethers.MaxUint256);
        });
    
        it("Correctly reduces the available deposit limit based on the contract's balance", async function () {
            const { strategy, investor, deployer } = await loadFixture(deployInvestorStrategyFixture);
            const depositAmount = 100;
    
            const distributedRewards = await investor.distributedRewards();

            const InvestorStrategy = await ethers.getContractAt("InvestorStrategy", strategy.target);
            const availableLimit = await InvestorStrategy.availableDepositLimit(deployer.address);
            const expectedLimit = ethers.MaxUint256 - distributedRewards;
            expect(availableLimit).to.equal(expectedLimit);
        });
    });

    describe("availableWithdrawLimit()", function () {
        async function setupScenario() {
            const { strategy, investor, deployer } = await loadFixture(deployInvestorStrategyFixture);
            
            // Simulate time passing
            await time.increase(10);

            await strategy.report();

            const distributedRewards = await investor.distributedRewards();

            const InvestorStrategy = await ethers.getContractAt("InvestorStrategy", strategy.target);
            const availableLimit = await InvestorStrategy.availableWithdrawLimit(deployer.address);
            return { availableLimit, distributedRewards };
        }
    
        it("Available Withdraw Limit is correct", async function () {
            const { availableLimit, distributedRewards } = await setupScenario();
            expect(availableLimit).to.equal(distributedRewards);
        });
    });
    
    describe("_deployFunds()", function () {
        it("Succesfully updates totalAssets on Strategy", async function () {
            const { vault, strategy, investor, asset, deployer } = await loadFixture(deployInvestorStrategyFixture);

            // Simulate time passing
            await time.increase(10);

            const deployAmount = 2000;
            await asset.approve(vault.target, deployAmount);
            await vault.setDepositLimit(deployAmount);
            await vault.deposit(deployAmount, deployer.address);

            await expect(vault.updateMaxDebtForStrategy(strategy.target, deployAmount))
                .to.emit(vault, 'UpdatedMaxDebtForStrategy')
                .withArgs(deployer.address, strategy.target, deployAmount);
    
            // Simulate the vault calling `updateDebt` which should trigger `_deployFunds`
            await vault.updateDebt(strategy.target, deployAmount);
    
            // Verify totalAssets is updated correctly
            const totalAssets = await strategy.totalAssets();
            const distributedRewards = await investor.distributedRewards();
            expect(totalAssets).to.equal(BigInt(deployAmount) + distributedRewards);
        });
    });

    describe("_freeFunds()", function () {
        it("Successfully withdraws funds from Strategy", async function () {
            const { vault, strategy, investor, asset, deployer, otherAccount } = await loadFixture(deployInvestorStrategyFixture);

            // Simulate time passing
            await time.increase(10);
            
            // Simulate the strategy investing funds
            const deployAmount = 2000;
            await asset.approve(vault.target, deployAmount);
            await vault.setDepositLimit(deployAmount);
            await vault.deposit(deployAmount, deployer.address);

            await expect(vault.updateMaxDebtForStrategy(strategy.target, deployAmount))
                .to.emit(vault, 'UpdatedMaxDebtForStrategy')
                .withArgs(deployer.address, strategy.target, deployAmount);
            
            await vault.updateDebt(strategy.target, deployAmount);
    
            // Perform withdrawal through the vault, triggering _freeFunds
            const withdrawalAmount = 50;
            await vault.withdraw(
                withdrawalAmount,
                otherAccount.address, // receiver
                deployer.address, // owner
                0,
                []
            );
    
            // Verify funds are transferred back to the user from the strategy through the vault
            const strategyBalanceAfter = await asset.balanceOf(otherAccount.address);
            expect(strategyBalanceAfter).to.equal(withdrawalAmount);

            // Verify totalAssets is updated correctly
            const totalAssets = await strategy.totalAssets();
            const distributedRewards = await investor.distributedRewards();
            const expectedInvestedAfter = deployAmount - withdrawalAmount;
            expect(totalAssets).to.equal(expectedInvestedAfter);
        });
    
        it("Reverts withdrawal if attempting to free more funds than available", async function () {
            const { vault, strategy, asset, manager, deployer, otherAccount } = await loadFixture(deployInvestorStrategyFixture);
    
            // Simulate the strategy investing funds
            const mintAmount = 5000;
            const deployAmount = 2000;
            await asset.mint(deployer.address, mintAmount);
            await asset.approve(vault.target, deployAmount);
            await vault.setDepositLimit(deployAmount);
            await vault.deposit(deployAmount, deployer.address);

            await expect(vault.updateMaxDebtForStrategy(strategy.target, deployAmount))
                .to.emit(vault, 'UpdatedMaxDebtForStrategy')
                .withArgs(deployer.address, strategy.target, deployAmount);
            
            await vault.updateDebt(strategy.target, deployAmount);
    
            // Attempt to withdraw more than the totalAssets
            const withdrawalAmount = 3000;
            await expect(vault.withdraw(
                withdrawalAmount,
                otherAccount.address, // receiver
                deployer.address, // owner
                0,
                [] // Adjust based on actual parameters
            )).to.be.revertedWithCustomError(vault, "InsufficientShares");
        });
    });
});
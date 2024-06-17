const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { ethers } = require("hardhat");
const { expect } = require("chai");
const { json } = require("stream/consumers");

// Fixture for deploying TradeFintechStrategy with all dependencies
async function deployTFStrategyFixture() {
    const profitMaxUnlockTime = 0;
    const uint256max = ethers.MaxUint256;

    const vaultName = 'Vault Shares FXD';
    const vaultSymbol = 'vFXD';
    const amount = "1000";
    const latestBlock = await time.latestBlock();
    const latestBlockTimestamp = (await ethers.provider.getBlock(latestBlock)).timestamp;
    const depositPeriodEnds = latestBlockTimestamp + 604800; // 1 week
    const lockPeriodEnds = depositPeriodEnds + (86400 * 30); // 30 days
    const depositLimit = ethers.parseEther("10000000") // 10,000,000

    const [deployer, manager, otherAccount, user, user2] = await ethers.getSigners();

    // Deploy MockERC20 as the asset
    const Asset = await ethers.getContractFactory("Token");
    const assetSymbol = 'FXD';
    const vaultDecimals = 18;
    const asset = await Asset.deploy(assetSymbol, vaultDecimals, { gasLimit: "0x1000000" });
    const assetType = 1; // 1 for Normal / 2 for Deflationary / 3 for Rebasing

    await asset.mint(deployer.address, ethers.parseEther(amount));
    await asset.mint(user.address, ethers.parseEther('20000'));
    await asset.mint(user2.address, ethers.parseEther('20000'));

    const performanceFee = 100; // 1% of gain
    const protocolFee = 2000; // 20% of total fee

    const Accountant = await ethers.getContractFactory("GenericAccountant");
    const accountant = await Accountant.deploy(performanceFee, deployer.address, deployer.address, { gasLimit: "0x1000000" });
    
    const VaultLogic = await ethers.getContractFactory("VaultLogic");
    const vaultLogic = await VaultLogic.deploy();

    const VaultPackage = await ethers.getContractFactory("VaultPackage", {
        libraries: {
            "VaultLogic": vaultLogic.target,
        }
    });
    const vaultPackage = await VaultPackage.deploy({ gasLimit: "0x1000000" });

    const FactoryPackage = await ethers.getContractFactory("FactoryPackage");
    const factoryPackage = await FactoryPackage.deploy({ gasLimit: "0x1000000" });

    const Factory = await ethers.getContractFactory("Factory");
    const factoryProxy = await Factory.deploy(factoryPackage.target, deployer.address, "0x", { gasLimit: "0x1000000" });

    const factory = await ethers.getContractAt("FactoryPackage", factoryProxy.target);
    await factory.initialize(vaultPackage.target, otherAccount.address, protocolFee);

    await factory.addVaultPackage(vaultPackage.target);

    await factory.deployVault(
        vaultPackage.target,
        profitMaxUnlockTime,
        assetType,
        asset.target,
        vaultName,
        vaultSymbol,
        accountant.target,
        deployer.address
    );

    const vaults = await factory.getVaults();
    const vault = await ethers.getContractAt("VaultPackage", vaults[0]);

    const STRATEGY_MANAGER = ethers.keccak256(ethers.toUtf8Bytes("STRATEGY_MANAGER"));
    const REPORTING_MANAGER = ethers.keccak256(ethers.toUtf8Bytes("REPORTING_MANAGER"));
    const DEBT_PURCHASER = ethers.keccak256(ethers.toUtf8Bytes("DEBT_PURCHASER"));

    await vault.grantRole(STRATEGY_MANAGER, deployer.address);
    await vault.grantRole(REPORTING_MANAGER, deployer.address);
    await vault.grantRole(DEBT_PURCHASER, deployer.address);

    // Deploy TokenizedStrategy
    const TokenizedStrategy = await ethers.getContractFactory("TokenizedStrategy");
    const tokenizedStrategy = await TokenizedStrategy.deploy(factoryProxy.target);

    // Deploy TradeFintechStrategy
    const TFStrategy = await ethers.getContractFactory("TradeFintechStrategy");
    const tfStrategy = await TFStrategy.deploy(
        asset.target,
        "Trade Fintech Strategy",
        tokenizedStrategy.target,
        depositPeriodEnds,
        lockPeriodEnds,
        depositLimit
    );

    const strategy = await ethers.getContractAt("TokenizedStrategy", tfStrategy.target);

    // Set new manager
    await strategy.setPendingManagement(manager.address);
    await strategy.connect(manager).acceptManagement();
    await strategy.connect(manager).setProfitMaxUnlockTime(0);

    // deploy and set KYCDepositLimitModule
    const KYCDepositLimitModule = await ethers.getContractFactory("KYCDepositLimitModule");
    const kycDepositLimitModule = await KYCDepositLimitModule.deploy(strategy.target, deployer.address);

    // set deposit limit as uint256 max
    await vault.setDepositLimit(uint256max);
    await vault.setDepositLimitModule(kycDepositLimitModule.target);
    await vault.addStrategy(strategy.target);
    await vault.updateMaxDebtForStrategy(strategy.target, depositLimit);
    // Set minimum deposit
    const minimumDeposit = ethers.parseEther("1000");
    await vault.setMinUserDeposit(minimumDeposit);

    await kycDepositLimitModule.setKYCPassed(user.address, true);
    await kycDepositLimitModule.setKYCPassed(user2.address, true);

    await asset.connect(user).approve(vault.target, uint256max);
    await asset.connect(user2).approve(vault.target, uint256max);
    await asset.connect(manager).approve(strategy.target, uint256max);

    return {
        vault, 
        strategy, 
        tfStrategy,
        asset, 
        user, 
        user2, 
        manager,
        depositPeriodEnds, 
        lockPeriodEnds, 
        depositLimit, 
        user, 
        kycDepositLimitModule, 
        minimumDeposit
    };
}

describe.only("TradeFintechStrategy-Vault tests", function () {

    describe("Min user deposit vaidation", function () {
        it("Set minimum user deposit", async function () {
            const { vault } = await loadFixture(deployTFStrategyFixture);

            const minimumDeposit = ethers.parseEther("10000");
            await vault.setMinUserDeposit(minimumDeposit);

            expect(await vault.minUserDeposit()).to.equal(minimumDeposit);
        });
    });

    describe("deposit()", function () {
        it("Revert if user try to deposit less than minimum", async function () {
            const { vault, user } = await loadFixture(deployTFStrategyFixture);

            const amount = ethers.parseEther("500");
            await expect(vault.deposit(amount, user.address)).to.be.revertedWithCustomError(vault, "MinDepositNotReached")
        });

        it("Revert if user didn't pass KYC verification", async function () {
            const { vault, user, kycDepositLimitModule, minimumDeposit } = await loadFixture(deployTFStrategyFixture);

            await kycDepositLimitModule.setKYCPassed(user.address, false);

            await expect(vault.deposit(minimumDeposit, user.address)).to.be.revertedWithCustomError(vault, "ExceedDepositLimit")
        });

        it("Successful deposit", async function () {
            const { vault, user, minimumDeposit } = await loadFixture(deployTFStrategyFixture);

            await vault.connect(user).deposit(minimumDeposit, user.address);

            const userBalance = await vault.balanceOf(user.address);
            expect(userBalance).to.equal(minimumDeposit);
        });

        it("Successful deposit more than min", async function () {
            const { vault, user, minimumDeposit } = await loadFixture(deployTFStrategyFixture);
            
            const amount = minimumDeposit + ethers.parseEther("10");
            await vault.connect(user).deposit(amount, user.address);

            const userBalance = await vault.balanceOf(user.address);
            expect(userBalance).to.equal(amount);
        });

        it("Revert if user try to deposit more than deposit limit", async function () {
            const { vault, asset, user, depositLimit } = await loadFixture(deployTFStrategyFixture);

            const amount = depositLimit + ethers.parseEther("1");

            await expect(vault.deposit(amount, user.address)).to.be.revertedWithCustomError(vault, "ExceedDepositLimit")
        });

        it("Revert if deposit period ended", async function () {
            const { vault, user, depositPeriodEnds } = await loadFixture(deployTFStrategyFixture);

            const amount = ethers.parseEther("1000");

            await time.increase(depositPeriodEnds + 1); // 1 week

            await expect(vault.deposit(amount, user.address)).to.be.revertedWithCustomError(vault, "ExceedDepositLimit")
        });

        it("Deposit of small amount after reaching deposit min", async function () {
            const { vault, user, minimumDeposit } = await loadFixture(deployTFStrategyFixture);

            await vault.connect(user).deposit(minimumDeposit, user.address);

            const amount = ethers.parseEther("500");

            await vault.connect(user).deposit(amount, user.address);
            const userBalance = await vault.balanceOf(user.address);
            expect(userBalance).to.equal(minimumDeposit + amount);
        });
    });

    describe("withdraw()", function () {
        it("Revert if leftover after withdraw > 0 and < minimum", async function () {
            const { vault, strategy, user, minimumDeposit } = await loadFixture(deployTFStrategyFixture);

            await vault.connect(user).deposit(minimumDeposit, user.address);

            const amount = ethers.parseEther("500");
            await expect(vault.withdraw(
                amount, 
                user.address,
                user.address,
                0,
                [strategy.target]
            )).to.be.revertedWithCustomError(vault, "MinDepositNotReached")
        });

        it("Withdraw all amount", async function () {
            const { vault, strategy, user, minimumDeposit } = await loadFixture(deployTFStrategyFixture);

            await vault.connect(user).deposit(minimumDeposit, user.address);
            await vault.connect(user).withdraw(
                minimumDeposit, 
                user.address,
                user.address,
                0,
                [strategy.target]
            );

            const userBalance = await vault.balanceOf(user.address);
            expect(userBalance).to.equal(0);
        });

        it("Leftover after withdraw > minimum", async function () {
            const { vault, strategy, user } = await loadFixture(deployTFStrategyFixture);

            // deposit
            const deposit = ethers.parseEther("1500");
            await vault.connect(user).deposit(deposit, user.address);

            const amount = ethers.parseEther("500");
            await vault.connect(user).withdraw(
                amount, 
                user.address,
                user.address,
                0,
                [strategy.target]
            );

            const userBalance = await vault.balanceOf(user.address);
            expect(userBalance).to.equal(deposit - amount);
        });

    });

    describe.only("lifesycle", function () {
        it("Ftate fintech vault lifecycle", async function () {
            const { vault, strategy, tfStrategy, user, depositLimit, asset, user2, manager} = await loadFixture(deployTFStrategyFixture);

            // set min user deposit 10k
            await vault.setMinUserDeposit(ethers.parseEther("10000"));

            // user deposit 15k
            const deposit = ethers.parseEther("15000");
            await vault.connect(user).deposit(deposit, user.address);

            // process deposit
            await vault.updateDebt(tfStrategy.target, deposit);

            // check max deposit
            const maxDeposit = await vault.maxDeposit(user.address);
            expect(maxDeposit).to.equal(depositLimit - deposit);

            let maxWithdraw1 = await vault.maxWithdraw(user.address, 0, [tfStrategy.target]);
            expect(maxWithdraw1).to.equal(deposit);

            // user withdraw 1k
            const amount = ethers.parseEther("5000");
            await vault.connect(user).withdraw(
                amount, 
                user.address,
                user.address,
                0,
                [tfStrategy.target]
            );

            // user 2 deposit 20k
            const deposit2 = ethers.parseEther("20000");
            await vault.connect(user2).deposit(deposit2, user2.address);

            const maxWithdraw2 = await vault.maxWithdraw(user2.address, 0, [tfStrategy.target]);
            expect(maxWithdraw2).to.equal(deposit2);

            // deposit time ended
            await vault.updateDebt(tfStrategy.target, ethers.parseEther("30000"));
            await time.increase(604800 + 1); // 1 week


            // max withdraw is 0
            expect(await vault.maxWithdraw(user.address, 0, [tfStrategy.target])).to.equal(0);
            expect(await vault.maxWithdraw(user2.address, 0, [tfStrategy.target])).to.equal(0);

            // max deposit is 0
            expect(await vault.maxDeposit(user.address)).to.equal(0);
            expect(await vault.maxDeposit(user2.address)).to.equal(0);


            // lock period ended
            await time.increase(86400 * 30 + 1); // 30 days

            // max withdraw is 0 because there was no repayment yet
            expect(await vault.maxWithdraw(user.address, 0, [tfStrategy.target])).to.equal(0);
            expect(await vault.maxWithdraw(user2.address, 0, [tfStrategy.target])).to.equal(0);

            console.log(await strategy.totalAssets());

            // mint 20% profit
            asset.mint(manager.address, ethers.parseEther("6000"));

            // process repayment with profit
            await tfStrategy.connect(manager).repay(ethers.parseEther("36000"));
            await strategy.report();
            await vault.processReport(tfStrategy.target);

            await strategy.report();
            await vault.processReport(tfStrategy.target);

            console.log(await strategy.totalAssets());
            console.log(await strategy.totalSupply());

            // expected balances - fees
            expect(await vault.convertToAssets(await vault.balanceOf(user.address))).to.equal('11976047904191616766467');
            expect(await vault.convertToAssets(await vault.balanceOf(user2.address))).to.equal('23952095808383233532934');
        });
    });
});
const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { ethers } = require("hardhat");
const { expect } = require("chai");

// Fixture for deploying TradeFintechStrategy with all dependencies
async function deployTFStrategyFixture() {
    const profitMaxUnlockTime = 30;
    const amount = "1000";
    const assetType = 1; // 1 for Normal / 2 for Deflationary / 3 for Rebasing
    const latestBlock = await time.latestBlock();
    const latestBlockTimestamp = (await ethers.provider.getBlock(latestBlock)).timestamp;
    const depositPeriodEnds = latestBlockTimestamp + 604800; // 1 week
    const lockPeriodEnds = latestBlockTimestamp + (86400 * 30); // 30 days
    const depositLimit = ethers.parseEther("1000000000000")

    const vaultName = 'Vault Shares FXD';
    const vaultSymbol = 'vFXD';
    const [deployer, manager, otherAccount] = await ethers.getSigners();

    // Deploy MockERC20 as the asset
    const Asset = await ethers.getContractFactory("Token");
    const assetSymbol = 'FXD';
    const vaultDecimals = 18;
    const asset = await Asset.deploy(assetSymbol, vaultDecimals, { gasLimit: "0x1000000" });

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

    await factory.addVaultPackage(vaultPackage.target);

    // Deploy TokenizedStrategy
    const TokenizedStrategy = await ethers.getContractFactory("TokenizedStrategy");
    const tokenizedStrategy = await TokenizedStrategy.deploy(factoryProxy.target);
    
    await factory.deployVault(
        0,
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

    // Add Strategy to Vault
    await expect(vault.addStrategy(strategy.target))
        .to.emit(vault, 'StrategyChanged')
        .withArgs(strategy.target, 0);
    await expect(vault.updateMaxDebtForStrategy(strategy.target, depositLimit))
        .to.emit(vault, 'UpdatedMaxDebtForStrategy')
        .withArgs(deployer.address, strategy.target, depositLimit);

    return { vault, strategy, asset, deployer, manager, otherAccount, depositPeriodEnds, lockPeriodEnds, depositLimit };
}

describe("TradeFintechStrategy tests", function () {

    describe("TradeFintechStrategy init tests", function () {
        it("Initializes with correct parameters", async function () {
            const { strategy, manager, depositPeriodEnds } = await loadFixture(deployTFStrategyFixture);
            const TFStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);

            const latestBlock = await time.latestBlock();
            const latestBlockTimestamp = (await ethers.provider.getBlock(latestBlock)).timestamp;

            expect(await strategy.management()).to.equal(manager.address);
            expect(await TFStrategy.depositPeriodEnds()).to.be.equal(depositPeriodEnds);
        });
    });

    describe("_harvestAndReport()", function () {
        it("Correctly transfer funds to manager and reports total assets", async function () {
            const { vault, strategy, asset, manager, deployer } = await loadFixture(deployTFStrategyFixture);

            const depositAmount = ethers.parseEther("100");
            await asset.mint(deployer.address, depositAmount);
            await asset.approve(vault.target, depositAmount);
            await vault.setDepositLimit(depositAmount);

            await vault.deposit(depositAmount, manager.address);
            await vault.updateDebt(strategy.target, depositAmount);
    
            await strategy.report();

            const TFStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
            const totalAssets = await TFStrategy.totalInvested();
            expect(totalAssets).to.equal(depositAmount);
            expect(await asset.balanceOf(manager.address)).to.equal(depositAmount);
        });

        it("Reverts when called by an unauthorized account", async function () {
            const { strategy, otherAccount } = await loadFixture(deployTFStrategyFixture);
    
            await expect(strategy.connect(otherAccount).report())
                .to.be.revertedWith("!keeper");
        });
    });

    describe("availableDepositLimit()", function () {
        it("Returns max uint256 when the contract holds no asset tokens", async function () {
            const { strategy, deployer, depositLimit } = await loadFixture(deployTFStrategyFixture);
            
            const TFStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
            const availableLimit = await TFStrategy.availableDepositLimit(deployer.address);
            expect(availableLimit).to.equal(depositLimit);
        });
    
        it("Correctly reduces the available deposit limit based on the contract's balance", async function () {
            const { strategy, asset, deployer, depositLimit } = await loadFixture(deployTFStrategyFixture);

            const depositAmount = ethers.parseEther("100");
    
            // Simulate the contract holding some amount of the asset tokens
            await asset.transfer(strategy.target, depositAmount);
    
            const TFStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
            const availableLimit = await TFStrategy.availableDepositLimit(deployer.address);
            const expectedLimit = depositLimit - depositAmount;
            expect(availableLimit).to.equal(expectedLimit);
        });
    });

    describe("availableWithdrawLimit()", function () {
        async function setupScenario(depositAmount) {
            const { strategy, asset, deployer } = await loadFixture(deployTFStrategyFixture);
            await asset.transfer(strategy.target, depositAmount);
            await strategy.report();
            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
            return tfStrategy.availableWithdrawLimit(deployer.address);
        }
    
        it("Returns 0 when there are no funds", async function () {
            const availableLimit = await setupScenario(0);
            expect(availableLimit).to.equal(0);
        });
    
        it("Return investments correctly", async function () {
            const depositAmount = ethers.parseEther("100");
            const availableLimit = await setupScenario(depositAmount);
            expect(availableLimit).to.equal(depositAmount);
        });
    });
    
    describe("_deployFunds()", function () {
        it("Transfers funds to the manager and updates totalInvestedInRWA when conditions are met", async function () {
            const { vault, strategy, asset, deployer, manager } = await loadFixture(deployTFStrategyFixture);

            const deployAmount = ethers.parseEther("100");
            await asset.approve(vault.target, deployAmount);
            await vault.setDepositLimit(deployAmount);
            await vault.deposit(deployAmount, deployer.address);

            await expect(vault.updateMaxDebtForStrategy(strategy.target, deployAmount))
                .to.emit(vault, 'UpdatedMaxDebtForStrategy')
                .withArgs(deployer.address, strategy.target, deployAmount);
    
            // Simulate the vault calling `updateDebt` which should trigger `_deployFunds`
            await vault.updateDebt(strategy.target, deployAmount);
    
            // Check that the funds were transferred to the manager
            const managerBalance = await asset.balanceOf(manager.address);
            expect(managerBalance).to.equal(deployAmount);
    
            // Verify totalInvestedInRWA was updated correctly
            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
            const totalInvestedInRWA = await tfStrategy.totalInvested();
            expect(totalInvestedInRWA).to.equal(deployAmount);
        });
    
        it("Does not transfer funds if depositPeriodEnds has been reached", async function () {
            const { vault, strategy, asset, deployer, manager } = await loadFixture(deployTFStrategyFixture);
    
            const deployAmount = ethers.parseEther("100");
            await asset.approve(vault.target, deployAmount);
            await vault.setDepositLimit(deployAmount);
            await vault.deposit(deployAmount, deployer.address);

            await expect(vault.updateMaxDebtForStrategy(strategy.target, deployAmount))
                .to.emit(vault, 'UpdatedMaxDebtForStrategy')
                .withArgs(deployer.address, strategy.target, deployAmount);
    
            // Record the initial manager balance
            const initialManagerBalance = await asset.balanceOf(manager.address);

            // Increase time to simulate the deposit period ending
            const TFStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
            const depositPeriodEnds = await TFStrategy.depositPeriodEnds();
            await time.increaseTo(depositPeriodEnds + BigInt(1));
    
            // Attempt to deploy funds after the deposit period has ended
            await expect(
                vault.updateDebt(strategy.target, deployAmount)
            ).to.be.revertedWith("Deposit period has ended");
    
            // Check that the funds were not transferred
            const managerBalance = await asset.balanceOf(manager.address);
            expect(managerBalance).to.equal(initialManagerBalance);
    
            // Verify totalInvestedInRWA was not updated
            const totalInvestedInRWA = await TFStrategy.totalInvested();
            expect(totalInvestedInRWA).to.equal(0);
        });
    });

    describe("_freeFunds()", function () {
        it("Successfully transfers funds and updates totalInvestedInRWA on withdrawal", async function () {
            const { vault, strategy, asset, manager, deployer, otherAccount } = await loadFixture(deployTFStrategyFixture);
            
            // Simulate the strategy investing funds
            const deployAmount = ethers.parseEther("100");
            await asset.approve(vault.target, deployAmount);
            await vault.setDepositLimit(deployAmount);
            await vault.deposit(deployAmount, deployer.address);

            await expect(vault.updateMaxDebtForStrategy(strategy.target, deployAmount))
                .to.emit(vault, 'UpdatedMaxDebtForStrategy')
                .withArgs(deployer.address, strategy.target, deployAmount);
            
            await vault.updateDebt(strategy.target, deployAmount);

            // Approve the strategy to spend the asset on behalf of the manager
            await asset.connect(manager).approve(strategy.target, deployAmount);

            // Increase time to simulate the lock period ending and withdrawing period starting
            const TFStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
            const depositPeriodEnds = await TFStrategy.lockPeriodEnds();
            await time.increaseTo(depositPeriodEnds + BigInt(1));
    
            // Perform withdrawal through the vault, triggering _freeFunds
            const withdrawalAmount = ethers.parseEther("50");
            await vault.withdraw(
                withdrawalAmount,
                otherAccount.address, // receiver
                deployer.address, // owner
                0,
                []
            );
    
            // Verify funds are transferred back to the user from the manager through the strategy
            const strategyBalanceAfter = await asset.balanceOf(otherAccount.address);
            expect(strategyBalanceAfter).to.equal(withdrawalAmount);
    
            // Verify totalInvestedInRWA is updated correctly
            const totalInvestedAfter = await TFStrategy.totalInvested();
            const expectedInvestedAfter = deployAmount - withdrawalAmount;
            expect(totalInvestedAfter).to.equal(expectedInvestedAfter);
        });
    
        it("Reverts withdrawal if attempting to free more funds than available", async function () {
            const { vault, strategy, asset, manager, deployer, otherAccount } = await loadFixture(deployTFStrategyFixture);
    
            // Simulate the strategy investing funds
            const deployAmount = ethers.parseEther("100");
            await asset.approve(vault.target, deployAmount);
            await vault.setDepositLimit(deployAmount);
            await vault.deposit(deployAmount, deployer.address);

            await expect(vault.updateMaxDebtForStrategy(strategy.target, deployAmount))
                .to.emit(vault, 'UpdatedMaxDebtForStrategy')
                .withArgs(deployer.address, strategy.target, deployAmount);
            
            await vault.updateDebt(strategy.target, deployAmount);

            // Approve the strategy to spend the asset on behalf of the manager
            await asset.connect(manager).approve(strategy.target, deployAmount);

            // Increase time to simulate the lock period ending and withdrawing period starting
            const TFStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
            const depositPeriodEnds = await TFStrategy.lockPeriodEnds();
            await time.increaseTo(depositPeriodEnds + BigInt(1));

            // Fake manager buying some RWA
            await asset.connect(manager).transfer(otherAccount.address, deployAmount);
    
            // Attempt to withdraw more than the manager's balance, expecting a revert
            const withdrawalAmount = ethers.parseEther("100");
            await expect(vault.withdraw(
                withdrawalAmount,
                otherAccount.address, // receiver
                deployer.address, // owner
                0,
                [] // Adjust based on actual parameters
            )).to.be.revertedWith("ERC20: transfer amount exceeds balance");
        });

        it("Reverts withdrawal if attempting to free funds before locksPeriod ends", async function () {
            const { vault, strategy, asset, manager, deployer, otherAccount } = await loadFixture(deployTFStrategyFixture);
    
            // Simulate the strategy investing funds
            const deployAmount = ethers.parseEther("100");
            await asset.approve(vault.target, deployAmount);
            await vault.setDepositLimit(deployAmount);
            await vault.deposit(deployAmount, deployer.address);

            await expect(vault.updateMaxDebtForStrategy(strategy.target, deployAmount))
                .to.emit(vault, 'UpdatedMaxDebtForStrategy')
                .withArgs(deployer.address, strategy.target, deployAmount);
            
            await vault.updateDebt(strategy.target, deployAmount);

            // Approve the strategy to spend the asset on behalf of the manager
            await asset.connect(manager).approve(strategy.target, deployAmount);
    
            // Attempt to withdraw more than the manager's balance, expecting a revert
            const withdrawalAmount = ethers.parseEther("100");
            await expect(vault.withdraw(
                withdrawalAmount,
                otherAccount.address, // receiver
                deployer.address, // owner
                0,
                [] // Adjust based on actual parameters
            )).to.be.revertedWith("Lock period has not ended");
        });
    });

    describe("_emergencyWithdraw()", function () {
        async function deployAndSetupScenario() {
            const { vault, strategy, asset, deployer, manager, otherAccount } = await loadFixture(deployTFStrategyFixture);
    
            // Simulate the strategy investing funds
            const deployAmount = ethers.parseEther("100");
            const emergencyWithdrawAmount = ethers.parseEther("50");
            await asset.mint(deployer.address, deployAmount);
            await asset.approve(vault.target, deployAmount);
            await vault.setDepositLimit(deployAmount);
            await vault.deposit(deployAmount, deployer.address);

            await expect(vault.updateMaxDebtForStrategy(strategy.target, deployAmount))
                .to.emit(vault, 'UpdatedMaxDebtForStrategy')
                .withArgs(deployer.address, strategy.target, deployAmount);

            await vault.updateDebt(strategy.target, deployAmount);
            await asset.connect(manager).approve(strategy.target, deployAmount);
    
            return { strategy, asset, manager, deployAmount, emergencyWithdrawAmount, otherAccount };
        }
    
        it("Successfully performs emergency withdrawal after shutdown", async function () {
            const { strategy, asset, manager, deployAmount, emergencyWithdrawAmount } = await deployAndSetupScenario();
    
            // Authorize and shutdown the strategy
            await strategy.connect(manager).shutdownStrategy();
    
            // Attempt emergency withdrawal            
            await strategy.connect(manager).emergencyWithdraw(emergencyWithdrawAmount);
    
            // Verify funds were transferred from strategy to manager
            const finalManagerBalance = await asset.balanceOf(manager.address);
            expect(finalManagerBalance).to.equal(deployAmount);

            const finalStrategyBalance = await asset.balanceOf(strategy.target);
            expect(finalStrategyBalance).to.equal(0);
        });
    
        it("Reverts emergency withdrawal if strategy is not shutdown", async function () {
            const { strategy, emergencyWithdrawAmount, manager } = await deployAndSetupScenario();
    
            // Attempt emergency withdrawal without shutting down the strategy
            await expect(
                strategy.connect(manager).emergencyWithdraw(emergencyWithdrawAmount)
            ).to.be.revertedWith("not shutdown");
        });

        it("Reverts emergency withdrawal if caller is not manager", async function () {
            const { strategy, emergencyWithdrawAmount, otherAccount } = await deployAndSetupScenario();
    
            // Attempt emergency withdrawal without shutting down the strategy
            await expect(
                strategy.connect(otherAccount).emergencyWithdraw(emergencyWithdrawAmount)
            ).to.be.revertedWith("!emergency authorized");
        });
    });

    describe("reportGainOrLoss()", function () {
        async function deployAndSetupScenarioForReporting() {
            const { strategy, asset, manager, deployer, otherAccount, vault } = await loadFixture(deployTFStrategyFixture);

            const depositAmount = ethers.parseEther("100");
            await asset.mint(deployer.address, depositAmount);
            await asset.approve(vault.target, depositAmount);
            await vault.setDepositLimit(depositAmount);

            await vault.deposit(depositAmount, manager.address);
            await vault.updateDebt(strategy.target, depositAmount);
    
            await strategy.report();
    
            // Simulate the strategy investing funds
            const investmentAmount = ethers.parseEther("100");
            await asset.transfer(strategy.target, investmentAmount);
            await strategy.report();
            return { strategy, asset, manager, deployer, investmentAmount, otherAccount };
        }
    
        it("Allows manager to report gain", async function () {
            const { strategy, manager } = await deployAndSetupScenarioForReporting();
            const gain = ethers.parseEther("10");

            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
    
            await expect(tfStrategy.connect(manager).reportGainOrLoss(gain, 0))
                .to.emit(tfStrategy, 'GainReported')
                .withArgs(manager.address, gain);
    
            const totalGains = await tfStrategy.totalGains();
            expect(totalGains).to.equal(gain);
        });
    
        it("Allows manager to report loss", async function () {
            const { strategy, manager } = await deployAndSetupScenarioForReporting();
            const loss = ethers.parseEther("10");

            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
    
            await expect(tfStrategy.connect(manager).reportGainOrLoss(0, loss))
                .to.emit(tfStrategy, 'LossReported')
                .withArgs(manager.address, loss);
    
            const totalLosses = await tfStrategy.totalLosses();
            expect(totalLosses).to.equal(loss);
        });
    
        it("Reverts if not called by manager", async function () {
            const { strategy, otherAccount } = await deployAndSetupScenarioForReporting();
            const gain = ethers.parseEther("5");

            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
    
            await expect(tfStrategy.connect(otherAccount).reportGainOrLoss(gain, 0))
                .to.be.revertedWith("!management");
        });
    
        it("Reverts if both gain and loss are reported", async function () {
            const { strategy, manager } = await deployAndSetupScenarioForReporting();
            const gain = ethers.parseEther("5");
            const loss = ethers.parseEther("5");

            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
    
            await expect(tfStrategy.connect(manager).reportGainOrLoss(gain, loss))
                .to.be.revertedWith("Cannot report both gain and loss");
        });
    
        it("Reverts if loss reported is more than total invested in RWA", async function () {
            const { strategy, manager, investmentAmount } = await deployAndSetupScenarioForReporting();
            const excessiveLoss = investmentAmount + ethers.parseEther("1"); // More than invested

            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
    
            await expect(tfStrategy.connect(manager).reportGainOrLoss(0, excessiveLoss))
                .to.be.revertedWith("Cannot report loss more than total invested");
        });
    });

    describe("returnFunds()", function () {
        async function deployAndSetupScenarioForReturningFunds() {
            const { strategy, asset, manager, deployer, otherAccount, vault } = await loadFixture(deployTFStrategyFixture);
    
            // Simulate the strategy deploying funds to the manager
            const depositAmount = ethers.parseEther("100");
            await asset.mint(deployer.address, depositAmount);
            await asset.approve(vault.target, depositAmount);
            await vault.setDepositLimit(depositAmount);

            await vault.deposit(depositAmount, manager.address);
            await vault.updateDebt(strategy.target, depositAmount);
    
            await strategy.report();
    
            return { strategy, asset, manager, deployer, otherAccount, depositAmount };
        }
    
        it("Allows manager to return funds to the strategy", async function () {
            const { strategy, asset, manager } = await deployAndSetupScenarioForReturningFunds();
            const returnAmount = ethers.parseEther("50");
    
            // Simulate manager holding funds to return
            await asset.transfer(manager.address, returnAmount);
            await asset.connect(manager).approve(strategy.target, returnAmount);
    
            const initialStrategyBalance = await asset.balanceOf(strategy.target);

            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
    
            await expect(tfStrategy.connect(manager).returnFunds(returnAmount))
                .to.emit(tfStrategy, 'FundsReturned')
                .withArgs(manager.address, returnAmount);
    
            const finalStrategyBalance = await asset.balanceOf(strategy.target);
            expect(finalStrategyBalance).to.equal(initialStrategyBalance + returnAmount);
        });
    
        it("Reverts if not called by manager", async function () {
            const { strategy, deployer } = await deployAndSetupScenarioForReturningFunds();
            const returnAmount = ethers.parseEther("10");

            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
    
            await expect(tfStrategy.connect(deployer).returnFunds(returnAmount))
                .to.be.revertedWith("!management");
        });
    
        it("Reverts if attempting to return 0 funds", async function () {
            const { strategy, manager } = await deployAndSetupScenarioForReturningFunds();

            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
    
            await expect(tfStrategy.connect(manager).returnFunds(0))
                .to.be.revertedWith("Amount must be greater than 0.");
        });
    
        it("Successfully updates TF Strategy balance after funds return", async function () {
            const { strategy, asset, manager } = await deployAndSetupScenarioForReturningFunds();
            const returnAmount = ethers.parseEther("50");
            
            // Simulate manager holding funds to return
            await asset.transfer(manager.address, returnAmount);
            await asset.connect(manager).approve(strategy.target, returnAmount);

            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
    
            const initialTFStrategyBalance = await asset.balanceOf(strategy.target);
    
            await tfStrategy.connect(manager).returnFunds(returnAmount);
    
            const finalTFStrategyBalance = await asset.balanceOf(strategy.target);
            expect(finalTFStrategyBalance).to.equal(initialTFStrategyBalance + returnAmount);
        });
    });

    describe("setDepositLimit()", function () {    
        it("Allows manager to set deposit limit", async function () {
            const { strategy, manager } = await loadFixture(deployTFStrategyFixture);
            const depositLimit = ethers.parseEther("50");

            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
    
            await tfStrategy.connect(manager).setDepositLimit(depositLimit);
    
            const newDepositLimit = await tfStrategy.depositLimit();
            expect(newDepositLimit).to.equal(depositLimit);
        });
    
        it("Reverts if not called by manager", async function () {
            const { strategy, deployer } = await loadFixture(deployTFStrategyFixture);
            const depositLimit = ethers.parseEther("50");

            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
    
            await expect(tfStrategy.connect(deployer).setDepositLimit(depositLimit))
                .to.be.revertedWith("!management");
        });
    
        it("Reverts if attempting to set 0 as new deposit limit", async function () {
            const { strategy, manager } = await loadFixture(deployTFStrategyFixture);

            const tfStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
    
            await expect(tfStrategy.connect(manager).setDepositLimit(0))
                .to.be.revertedWith("Deposit limit must be greater than 0.");
        });
    });    
});
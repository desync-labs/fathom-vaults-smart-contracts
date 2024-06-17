const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { ethers } = require("hardhat");
const { expect } = require("chai");

// Fixture for deploying RWAStrategy with all dependencies
async function deployRWAStrategyFixture() {
    const minDeployAmount = 1000;
    const amount = "1000";

    const [deployer, manager, otherAccount] = await ethers.getSigners();

    // Deploy MockERC20 as the asset
    const Asset = await ethers.getContractFactory("Token");
    const assetSymbol = 'FXD';
    const vaultDecimals = 18;
    const asset = await Asset.deploy(assetSymbol, vaultDecimals, { gasLimit: "0x1000000" });
    const depositLimit = ethers.parseEther("1000000000000")

    await asset.mint(deployer.address, ethers.parseEther(amount));

    const protocolFee = 2000; // 20% of total fee

    const VaultLogic = await ethers.getContractFactory("VaultLogic");
    const vaultLogic = await VaultLogic.deploy({ gasLimit: "0x1000000" });

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

    // Deploy TokenizedStrategy
    const TokenizedStrategy = await ethers.getContractFactory("TokenizedStrategy");
    const tokenizedStrategy = await TokenizedStrategy.deploy(factoryProxy.target);
    
    // Deploy RWAStrategy
    const RWAStrategy = await ethers.getContractFactory("RWAStrategy");
    const rwaStrategy = await RWAStrategy.deploy(
        asset.target,
        "RWA Strategy",
        tokenizedStrategy.target,
        manager.address,
        minDeployAmount,
        depositLimit
    );

    const strategy = await ethers.getContractAt("TokenizedStrategy", rwaStrategy.target);

    return { strategy, asset, deployer, manager, otherAccount, depositLimit, rwaStrategy };
}

describe("RWAStrategy tests", function () {
    describe("RWAStrategy init tests", function () {
        it("Initializes with correct parameters", async function () {
            const { strategy, manager } = await loadFixture(deployRWAStrategyFixture);
            const RWAStrategy = await ethers.getContractAt("RWAStrategy", strategy.target);
            expect(await RWAStrategy.managerAddress()).to.equal(manager.address);
            expect(await RWAStrategy.minDeployAmount()).to.equal(1000);
        });
    });

    describe("_harvestAndReport()", function () {
        it("Correctly reports total assets", async function () {
            const { strategy, asset, manager } = await loadFixture(deployRWAStrategyFixture);
    
            await asset.transfer(strategy.target, ethers.parseEther("10"));
            await strategy.report();

            const RWAStrategy = await ethers.getContractAt("RWAStrategy", strategy.target);
            const totalAssets = await RWAStrategy.totalInvested();
            expect(totalAssets).to.equal(ethers.parseEther("10"));
        });

        it("Reverts when called by an unauthorized account", async function () {
            const { strategy, otherAccount } = await loadFixture(deployRWAStrategyFixture);
    
            await expect(strategy.connect(otherAccount).report())
                .to.be.revertedWith("!keeper");
        });

        it("Does not transfer funds if minDeployAmount is not reached", async function () {
            const { strategy, asset, manager } = await loadFixture(deployRWAStrategyFixture);
            const initialManagerBalance = await asset.balanceOf(manager.address);
    
            // Ensure the strategy has some balance but below minDeployAmount
            const belowMinAmount = 1;
            await asset.transfer(strategy.target, belowMinAmount);
    
            // Attempt to call report(), which should not transfer any funds
            await strategy.report();
    
            // Verify that the manager's balance hasn't increased, implying no transfer
            expect(await asset.balanceOf(manager.address)).to.equal(initialManagerBalance);
    
            // Additionally, verify the strategy's balance remains unchanged (still holds the belowMinAmount)
            expect(await asset.balanceOf(strategy.target)).to.equal(belowMinAmount);
        });
    });

    describe("availableDepositLimit()", function () {
        it("Returns depositLimit when the contract holds no asset tokens", async function () {
            const { strategy, deployer, depositLimit } = await loadFixture(deployRWAStrategyFixture);
            
            const RWAStrategy = await ethers.getContractAt("RWAStrategy", strategy.target);
            const availableLimit = await RWAStrategy.availableDepositLimit(deployer.address);
            expect(availableLimit).to.equal(depositLimit);
        });
    
        it("Correctly reduces the available deposit limit based on the contract's balance", async function () {
            const { strategy, asset, deployer, depositLimit } = await loadFixture(deployRWAStrategyFixture);
            const depositAmount = 100;
    
            // Simulate the contract holding some amount of the asset tokens
            await asset.transfer(strategy.target, depositAmount);
    
            const RWAStrategy = await ethers.getContractAt("RWAStrategy", strategy.target);
            const availableLimit = await RWAStrategy.availableDepositLimit(deployer.address);
            const expectedLimit = depositLimit - BigInt(depositAmount);
            expect(availableLimit).to.equal(expectedLimit);
        });
    });

    describe("availableWithdrawLimit()", function () {
        async function setupScenario(idleFunds, investedFunds) {
            const { strategy, asset, deployer } = await loadFixture(deployRWAStrategyFixture);
            await asset.transfer(strategy.target, idleFunds);
            await asset.transfer(strategy.target, investedFunds);
            await strategy.report();
            const rwaStrategy = await ethers.getContractAt("RWAStrategy", strategy.target);
            return rwaStrategy.availableWithdrawLimit(deployer.address);
        }
    
        it("Returns 0 when there are no funds", async function () {
            const availableLimit = await setupScenario(0, 0);
            expect(availableLimit).to.equal(0);
        });
    
        it("Reflects only idle funds when no investments are made", async function () {
            const idleFunds = 100;
            const availableLimit = await setupScenario(idleFunds, 0);
            expect(availableLimit).to.equal(idleFunds);
        });
    
        it("Reflects only investments when there are no idle funds", async function () {
            const investedFunds = 2000;
            const availableLimit = await setupScenario(0, investedFunds);
            expect(availableLimit).to.equal(investedFunds);
        });
    
        it("Sums idle funds and investments correctly", async function () {
            const idleFunds = 100;
            const investedFunds = 2000;
            const expectedTotal = idleFunds + investedFunds;
            const availableLimit = await setupScenario(idleFunds, investedFunds);
            expect(availableLimit).to.equal(expectedTotal);
        });
    });


    describe("reportGain()", function () {
        async function deployAndSetupScenarioForReporting() {
            const { strategy, asset, manager, deployer, otherAccount, rwaStrategy } = await loadFixture(deployRWAStrategyFixture);

            const depositAmount = ethers.parseEther("1000");
            await asset.mint(deployer.address, depositAmount);
            await asset.approve(strategy.target, depositAmount);
            await strategy.deposit(depositAmount, deployer.address);
    
            await strategy.report();

            return { strategy, asset, manager, deployer, otherAccount, rwaStrategy };
        }
    
        it("Allows manager to report gain", async function () {
            const { asset, manager, rwaStrategy } = await deployAndSetupScenarioForReporting();
            const gain = ethers.parseEther("10");

            const balanceBefore = await asset.balanceOf(rwaStrategy.target);
            await asset.connect(manager).approve(rwaStrategy.target, gain);

            await expect(rwaStrategy.connect(manager).reportGain(gain))
                .to.emit(rwaStrategy, 'GainReported')
                .withArgs(manager.address, gain);

            const balanceAfter = await asset.balanceOf(rwaStrategy.target);
    
            const totalGains = balanceAfter - balanceBefore;
            expect(totalGains).to.equal(gain);
        });
    
        it("Reverts if not called by manager", async function () {
            const { rwaStrategy, otherAccount } = await deployAndSetupScenarioForReporting();
            const gain = ethers.parseEther("5");

            await expect(rwaStrategy.connect(otherAccount).reportGain(gain))
                .to.be.revertedWithCustomError(rwaStrategy, "NotRWAManager");
        });
    
        it("Reverts if 0 reported ", async function () {
            const { rwaStrategy, manager } = await deployAndSetupScenarioForReporting();

            await expect(rwaStrategy.connect(manager).reportGain(0))
                .to.be.revertedWithCustomError(rwaStrategy, "ZeroAmount");
        });
    });

    describe("reportLoss()", function () {
        async function deployAndSetupScenarioForReporting() {
            const { strategy, asset, manager, deployer, otherAccount, rwaStrategy } = await loadFixture(deployRWAStrategyFixture);

            const depositAmount = ethers.parseEther("100");
            await asset.mint(deployer.address, depositAmount);
            await asset.approve(strategy.target, depositAmount);
            await strategy.deposit(depositAmount, deployer.address);
    
            await strategy.report();
    
            return { strategy, asset, manager, deployer, otherAccount, rwaStrategy };
        }
    
        it("Allows manager to report loss", async function () {
            const { manager, rwaStrategy } = await deployAndSetupScenarioForReporting();
            const loss = ethers.parseEther("10");

            const totalInvestedBefore = await rwaStrategy.totalInvested();

            await expect(rwaStrategy.connect(manager).reportLoss(loss))
                .to.emit(rwaStrategy, 'LossReported')
                .withArgs(manager.address, loss);
    
            const totalInvested = await rwaStrategy.totalInvested();
            expect(totalInvested).to.equal(totalInvestedBefore-loss);
        });
    
        it("Reverts if not called by manager", async function () {
            const { rwaStrategy, otherAccount } = await deployAndSetupScenarioForReporting();
            const amount = ethers.parseEther("5");

            await expect(rwaStrategy.connect(otherAccount).reportLoss(amount))
                .to.be.revertedWithCustomError(rwaStrategy, "NotRWAManager");
        });
    
        it("Reverts if loss reported is more than total invested", async function () {
            const { rwaStrategy, manager } = await deployAndSetupScenarioForReporting();

            const investmentAmount = await rwaStrategy.totalInvested();
            const excessiveLoss = investmentAmount + ethers.parseEther("1"); // More than invested

            await expect(rwaStrategy.connect(manager).reportLoss(excessiveLoss))
                .to.be.revertedWithCustomError(rwaStrategy, "InvalidLossAmount");
        });

        it("Reverts if 0 reported ", async function () {
            const { rwaStrategy, manager } = await deployAndSetupScenarioForReporting();

            await expect(rwaStrategy.connect(manager).reportLoss(0))
                .to.be.revertedWithCustomError(rwaStrategy, "ZeroAmount");
        });
    });

    
    describe("_deployFunds()", function () {
        it("Transfers funds to the manager and updates totalInvested when conditions are met", async function () {
            const { strategy, asset, deployer, manager, rwaStrategy } = await loadFixture(deployRWAStrategyFixture);

            const deployAmount = 2000;
            await asset.approve(strategy.target, deployAmount);
            await strategy.deposit(deployAmount, deployer.address);

            // Check that the funds were transferred to the manager
            const managerBalance = await asset.balanceOf(manager.address);
            expect(managerBalance).to.equal(deployAmount);
    
            // Verify totalInvested was updated correctly
            const totalInvested = await rwaStrategy.totalInvested();
            expect(totalInvested).to.equal(deployAmount);
        });
    
        it("Does not transfer funds if amount does not exceed minDeployAmount", async function () {
            const { strategy, asset, deployer, manager, rwaStrategy } = await loadFixture(deployRWAStrategyFixture);
    
            // Record the initial manager balance
            const initialManagerBalance = await asset.balanceOf(manager.address);
    
            const deployAmount = 50;
            await asset.approve(strategy.target, deployAmount);
            await strategy.deposit(deployAmount, deployer.address);
    
            // Check that the funds were not transferred
            const managerBalance = await asset.balanceOf(manager.address);
            expect(managerBalance).to.equal(initialManagerBalance);
    
            // Verify totalInvested was not updated
            const totalInvested = await rwaStrategy.totalInvested();
            expect(totalInvested).to.equal(0);
        });
    });

    describe("_freeFunds()", function () {
        it("Successfully transfers funds and updates totalInvested on withdrawal", async function () {
            const { strategy, asset, manager, deployer, otherAccount, rwaStrategy } = await loadFixture(deployRWAStrategyFixture);
            
            // Simulate the strategy investing funds
            const deployAmount = 2000;
            await asset.approve(strategy.target, deployAmount);
            await strategy.deposit(deployAmount, deployer.address);

            // Approve the strategy to spend the asset on behalf of the manager
            await asset.connect(manager).approve(strategy.target, deployAmount);
    
            // Perform withdrawal through the vault, triggering _freeFunds
            const withdrawalAmount = 50;
            await strategy.withdraw(withdrawalAmount, otherAccount.address, deployer.address);
    
            // Verify funds are transferred back to the user from the manager through the strategy
            const strategyBalanceAfter = await asset.balanceOf(otherAccount.address);
            expect(strategyBalanceAfter).to.equal(withdrawalAmount);
    
            // Verify totalInvested is updated correctly
            const totalInvestedAfter = await rwaStrategy.totalInvested();
            const expectedInvestedAfter = deployAmount - withdrawalAmount;
            expect(totalInvestedAfter).to.equal(expectedInvestedAfter);
        });
    
        it("Reverts withdrawal if attempting to free more funds than available", async function () {
            const { strategy, asset, manager, deployer, otherAccount, rwaStrategy } = await loadFixture(deployRWAStrategyFixture);
    
            // Simulate the strategy investing funds
            const deployAmount = 2000;
            await asset.approve(strategy.target, deployAmount);
            await strategy.deposit(deployAmount, deployer.address);

            // Approve the strategy to spend the asset on behalf of the manager
            await asset.connect(manager).approve(strategy.target, deployAmount);

            // Fake manager buying some RWA
            await asset.connect(manager).transfer(otherAccount.address, deployAmount);
    
            // Attempt to withdraw more than the manager's balance, expecting a revert
            const withdrawalAmount = 2000; // More than manager's balance

            await expect(
                strategy.withdraw(withdrawalAmount, otherAccount.address, deployer.address)
            ).to.be.revertedWithCustomError(rwaStrategy, "ManagerBalanceTooLow");
        });
    });

    describe("_emergencyWithdraw()", function () {
        async function deployAndSetupScenario() {
            const { strategy, asset, deployer, manager, otherAccount, rwaStrategy } = await loadFixture(deployRWAStrategyFixture);
    
            // Simulate the strategy investing funds
            const deployAmount = ethers.parseEther("1000");
            await asset.approve(strategy.target, deployAmount);
            await strategy.deposit(deployAmount, deployer.address);
     
            await asset.connect(manager).approve(strategy.target, deployAmount);
    
            return { strategy, asset, manager, deployAmount, otherAccount, rwaStrategy, deployAmount};
        }
    
        it("Successfully performs emergency withdrawal after shutdown", async function () {
            const { strategy, rwaStrategy, asset, deployAmount,  } = await deployAndSetupScenario();
    
            // Authorize and shutdown the strategy
            await strategy.shutdownStrategy();

            const emergencyWithdrawAmount1 = ethers.parseEther("600");
            const expectedDebtAfterWithrawal1 = deployAmount - emergencyWithdrawAmount1;

            expect(await asset.balanceOf(strategy.target)).to.equal(0);

            // check initial RWAStrategy accounting
            expect(await rwaStrategy.totalInvested()).to.equal(deployAmount);    

            // check initial TokenizedStrategy accounting
            expect(await strategy.totalDebt()).to.equal(deployAmount);
            expect(await strategy.totalIdle()).to.equal(0);     
            expect(await strategy.totalAssets()).to.equal(deployAmount);
    
            // Eemergency withdrawal some amount           
            await strategy.emergencyWithdraw(emergencyWithdrawAmount1);
    
            // Verify funds were withdrawn
            expect(await asset.balanceOf(strategy.target)).to.equal(emergencyWithdrawAmount1);
    
            // Verify RWAStrategy accounting
            expect(await rwaStrategy.totalInvested()).to.equal(expectedDebtAfterWithrawal1);   

            // Verify TokenizedStrategy accounting
            expect(await strategy.totalDebt()).to.equal(expectedDebtAfterWithrawal1);
            expect(await strategy.totalIdle()).to.equal(emergencyWithdrawAmount1);     
            expect(await strategy.totalAssets()).to.equal(deployAmount);

            // Eemergency withdrawal the rest     
            await strategy.emergencyWithdraw(expectedDebtAfterWithrawal1);

            // Verify funds were withdrawn
            expect(await asset.balanceOf(strategy.target)).to.equal(deployAmount);
    
            // Verify RWAStrategy accounting
            expect(await rwaStrategy.totalInvested()).to.equal(0);   

            // Verify TokenizedStrategy accounting
            expect(await strategy.totalDebt()).to.equal(0);
            expect(await strategy.totalIdle()).to.equal(deployAmount);     
            expect(await strategy.totalAssets()).to.equal(deployAmount);
        });

        it("Handles withdrawal exceeding the current balance by withdrawing available", async function () {
            const { strategy, asset, manager, rwaStrategy, deployAmount, otherAccount } = await deployAndSetupScenario();
    
            // Authorize and shutdown the strategy
            await strategy.shutdownStrategy();
    
            const expectedWithdrawal = ethers.parseEther("550");
            const managerBalance = await asset.balanceOf(manager.address);

            // reduce the balance of the manager
            await asset.connect(manager).transfer(otherAccount.address, managerBalance - expectedWithdrawal);

            // Attempt emergency withdrawal
            await strategy.emergencyWithdraw(deployAmount);
    
            // Verify funds were withdrawn
            expect(await asset.balanceOf(strategy.target)).to.equal(ethers.parseEther("550"));
    
            // Verify RWAStrategy accounting
            expect(await rwaStrategy.totalInvested()).to.equal(ethers.parseEther("450"));   

            // Verify TokenizedStrategy accounting
            expect(await strategy.totalDebt()).to.equal(ethers.parseEther("450"));
            expect(await strategy.totalIdle()).to.equal(ethers.parseEther("550"));     
            expect(await strategy.totalAssets()).to.equal(ethers.parseEther("1000"));
        });

        it("Reverts emergency withdrawal if amount is bigger than total invested", async function () {
            const { strategy, rwaStrategy } = await deployAndSetupScenario();
    
            // Authorize and shutdown the strategy
            await strategy.shutdownStrategy();

            // Attempt emergency withdrawal without shutting down the strategy
            const totalInvested = await rwaStrategy.totalInvested();
            await expect(
                strategy.emergencyWithdraw(totalInvested + BigInt(1))
            ).to.be.revertedWithCustomError(rwaStrategy, "InsufficientFundsLocked");
        });
    
        it("Reverts emergency withdrawal if strategy is not shutdown", async function () {
            const { strategy } = await deployAndSetupScenario();
    
            // Attempt emergency withdrawal without shutting down the strategy
            await expect(
                strategy.emergencyWithdraw(ethers.parseEther("100"))
            ).to.be.revertedWith("not shutdown");
        });

        it("Reverts emergency withdrawal if caller is not manager", async function () {
            const { strategy, otherAccount } = await deployAndSetupScenario();
    
            // Attempt emergency withdrawal without shutting down the strategy
            await expect(
                strategy.connect(otherAccount).emergencyWithdraw(ethers.parseEther("100"))
            ).to.be.revertedWith("!emergency authorized");
        });
    });

    describe("setMinDeployAmountToSell()", function () {    
        it("Allows management to update minDeployAmount", async function () {
            const { rwaStrategy } = await loadFixture(deployRWAStrategyFixture);
            const newMinAmount = 500;
    
            await rwaStrategy.setMinDeployAmount(newMinAmount);
    
            const updatedMinAmount = await rwaStrategy.minDeployAmount();
            expect(updatedMinAmount).to.equal(newMinAmount);
        });
    
        it("Reverts when a non-management user tries to update minDeployAmount", async function () {
            const { strategy, otherAccount, rwaStrategy } = await loadFixture(deployRWAStrategyFixture);
            const newMinAmount = 500;

            await expect(rwaStrategy.connect(otherAccount).setMinDeployAmount(newMinAmount))
                .to.be.revertedWith("!management");
        });
    });
});
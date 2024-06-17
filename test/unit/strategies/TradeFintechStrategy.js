const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { ethers } = require("hardhat");
const { expect } = require("chai");

// Fixture for deploying TradeFintechStrategy with all dependencies
async function deployTFStrategyFixture() {
    const amount = "1000";
    const latestBlock = await time.latestBlock();
    const latestBlockTimestamp = (await ethers.provider.getBlock(latestBlock)).timestamp;
    const depositPeriodEnds = latestBlockTimestamp + 604800; // 1 week
    const lockPeriodEnds = depositPeriodEnds + (86400 * 30); // 30 days
    const depositLimit = ethers.parseEther("1000000000000")

    const [deployer, manager, otherAccount] = await ethers.getSigners();

    // Deploy MockERC20 as the asset
    const Asset = await ethers.getContractFactory("Token");
    const assetSymbol = 'FXD';
    const vaultDecimals = 18;
    const asset = await Asset.deploy(assetSymbol, vaultDecimals, { gasLimit: "0x1000000" });

    await asset.mint(deployer.address, ethers.parseEther(amount));

    const FactoryPackage = await ethers.getContractFactory("FactoryPackage");
    const factoryPackage = await FactoryPackage.deploy({ gasLimit: "0x1000000" });

    const Factory = await ethers.getContractFactory("Factory");
    const factoryProxy = await Factory.deploy(factoryPackage.target, deployer.address, "0x", { gasLimit: "0x1000000" });

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

    return { strategy, asset, deployer, manager, otherAccount, depositPeriodEnds, lockPeriodEnds, depositLimit, tfStrategy };
}

describe("TradeFintechStrategy tests", function () {

    describe("TradeFintechStrategy init tests", function () {
        it("Initializes with correct parameters", async function () {
            const { strategy, manager, depositPeriodEnds, tfStrategy } = await loadFixture(deployTFStrategyFixture);

            expect(await strategy.management()).to.equal(manager.address);
            expect(await tfStrategy.depositPeriodEnds()).to.be.equal(depositPeriodEnds);
        });
    });

    describe("_harvestAndReport()", function () {
        it("Correctly transfer funds to manager and reports total assets", async function () {
            const { strategy, asset, manager, deployer, tfStrategy} = await loadFixture(deployTFStrategyFixture);

            const depositAmount = ethers.parseEther("100");
            await asset.mint(deployer.address, depositAmount);
            await asset.approve(strategy.target, depositAmount);
            await strategy.deposit(depositAmount, deployer.address);
    
            await strategy.report();

            const totalAssets = await tfStrategy.totalInvested();
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
            const { deployer, depositLimit, tfStrategy } = await loadFixture(deployTFStrategyFixture);
            
            const availableLimit = await tfStrategy.availableDepositLimit(deployer.address);
            expect(availableLimit).to.equal(depositLimit);
        });

        it("Returns 0 when the deposit period has ended", async function () {
            const { deployer, tfStrategy } = await loadFixture(deployTFStrategyFixture);

            const depositPeriodEnds = await tfStrategy.depositPeriodEnds();
            await time.increaseTo(depositPeriodEnds + BigInt(1));

            const availableLimit = await tfStrategy.availableDepositLimit(deployer.address);
            expect(availableLimit).to.equal(0);
        });
    
        it("Correctly reduces the available deposit limit based on the contract's balance", async function () {
            const { asset, strategy, deployer, depositLimit, tfStrategy } = await loadFixture(deployTFStrategyFixture);

            const depositAmount = ethers.parseEther("100");
    
            // Simulate the contract holding some amount of the asset tokens
            await asset.approve(strategy.target, depositAmount);
            await strategy.deposit(depositAmount, deployer.address);

            const availableLimit = await tfStrategy.availableDepositLimit(deployer.address);
            console.log(await tfStrategy.totalInvested())

            const expectedLimit = depositLimit - depositAmount;
            expect(availableLimit).to.equal(expectedLimit);
        });
    });

    describe("availableWithdrawLimit()", function () {
        it("Returns 0 when there are no funds", async function () {
            const { deployer, tfStrategy } = await loadFixture(deployTFStrategyFixture);

            const availableLimit = await tfStrategy.availableWithdrawLimit(deployer.address);
            expect(availableLimit).to.equal(0);
        });

        it("Returns 0 when there lock period is not ended", async function () {
            const { asset, strategy, deployer, tfStrategy } = await loadFixture(deployTFStrategyFixture);

            const depositAmount = ethers.parseEther("100");
            await asset.approve(strategy.target, depositAmount);
            await strategy.deposit(depositAmount, deployer.address);
            await strategy.report();

            let availableLimit = await tfStrategy.availableWithdrawLimit(deployer.address);
            expect(availableLimit).to.equal(0);

            const lockPeriodEnds = await tfStrategy.lockPeriodEnds();
            await time.increaseTo(lockPeriodEnds + BigInt(1));

            availableLimit = await tfStrategy.availableWithdrawLimit(deployer.address);
            expect(availableLimit).to.equal(depositAmount);
        });
    
        it("Return investments correctly", async function () {
            const { strategy, asset, deployer, tfStrategy } = await loadFixture(deployTFStrategyFixture);

            const depositAmount = ethers.parseEther("100");
            await asset.approve(strategy.target, depositAmount);
            await strategy.deposit(depositAmount, deployer.address);
            await strategy.report();

            const lockPeriodEnds = await tfStrategy.lockPeriodEnds();
            await time.increaseTo(lockPeriodEnds + BigInt(1));
            const availableLimit = await tfStrategy.availableWithdrawLimit(deployer.address);

            expect(availableLimit).to.equal(depositAmount);
        });
    });
    
    describe("_deployFunds()", function () {
        it("Transfers funds to the manager and updates totalInvestedInRWA when conditions are met", async function () {
            const { strategy, asset, deployer, manager, tfStrategy } = await loadFixture(deployTFStrategyFixture);

            const deployAmount = ethers.parseEther("100");
            await asset.approve(strategy.target, deployAmount);
            await strategy.deposit(deployAmount, deployer.address);

            // Check that the funds were transferred to the manager
            const managerBalance = await asset.balanceOf(manager.address);
            expect(managerBalance).to.equal(deployAmount);
    
            // Verify totalInvestedInRWA was updated correctly
            const totalInvestedInRWA = await tfStrategy.totalInvested();
            expect(totalInvestedInRWA).to.equal(deployAmount);
        });
    
        it("Does not transfer funds if depositPeriodEnds has been reached", async function () {
            const { strategy, asset, deployer, manager, tfStrategy } = await loadFixture(deployTFStrategyFixture);
    
            const deployAmount = ethers.parseEther("100");
            // Record the initial manager balance
            const initialManagerBalance = await asset.balanceOf(manager.address);

            // Increase time to simulate the deposit period ending
            const depositPeriodEnds = await tfStrategy.depositPeriodEnds();
            await time.increaseTo(depositPeriodEnds + BigInt(1));

            await asset.approve(strategy.target, deployAmount);

            await expect(
                strategy.deposit(deployAmount, deployer.address)
            ).to.be.revertedWith("ERC4626: deposit more than max");
    
            // Check that the funds were not transferred
            const managerBalance = await asset.balanceOf(manager.address);
            expect(managerBalance).to.equal(initialManagerBalance);
    
            // Verify totalInvestedInRWA was not updated
            const totalInvestedInRWA = await tfStrategy.totalInvested();
            expect(totalInvestedInRWA).to.equal(0);
        });
    });

    describe("_freeFunds()", function () {
        it("Successfully transfers funds and updates totalInvestedInRWA on withdrawal", async function () {
            const { strategy, asset, manager, deployer, otherAccount } = await loadFixture(deployTFStrategyFixture);
            
            // Simulate the strategy investing funds
            const deployAmount = ethers.parseEther("100");
            await asset.approve(strategy.target, deployAmount);
            await strategy.deposit(deployAmount, deployer.address);

            // Approve the strategy to spend the asset on behalf of the manager
            await asset.connect(manager).approve(strategy.target, deployAmount);

            // Increase time to simulate the lock period ending and withdrawing period starting
            const TFStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
            const lockPeriodEnds = await TFStrategy.lockPeriodEnds();
            await time.increaseTo(lockPeriodEnds + BigInt(1));
    
            // Perform withdrawal through the vault, triggering _freeFunds
            const withdrawalAmount = ethers.parseEther("50");
            await strategy.withdraw(withdrawalAmount, otherAccount.address, deployer.address);
    
            // Verify funds are transferred back to the user from the manager through the strategy
            const strategyBalanceAfter = await asset.balanceOf(otherAccount.address);
            expect(strategyBalanceAfter).to.equal(withdrawalAmount);
    
            // Verify totalInvestedInRWA is updated correctly
            const totalInvestedAfter = await TFStrategy.totalInvested();
            const expectedInvestedAfter = deployAmount - withdrawalAmount;
            expect(totalInvestedAfter).to.equal(expectedInvestedAfter);
        });
    
        it("Reverts withdrawal if attempting to free more funds than available", async function () {
            const { strategy, asset, manager, deployer, otherAccount, tfStrategy } = await loadFixture(deployTFStrategyFixture);
    
            // Simulate the strategy investing funds
            const deployAmount = ethers.parseEther("100");
            await asset.approve(strategy.target, deployAmount);
            await strategy.deposit(deployAmount, deployer.address);

            // Approve the strategy to spend the asset on behalf of the manager
            await asset.connect(manager).approve(strategy.target, deployAmount);

            // Increase time to simulate the lock period ending and withdrawing period starting
            const lockPeriodEnds = await tfStrategy.lockPeriodEnds();
            await time.increaseTo(lockPeriodEnds + BigInt(1));

            // Fake manager buying some RWA
            await asset.connect(manager).transfer(otherAccount.address, deployAmount);
    
            // Attempt to withdraw more than the manager's balance, expecting a revert
            const withdrawalAmount = ethers.parseEther("100");
            await expect(
                strategy.withdraw(withdrawalAmount, otherAccount.address, deployer.address)
            ).to.be.revertedWithCustomError(tfStrategy, "ManagerBalanceTooLow");
        });

        it("Reverts withdrawal if attempting to free funds before locksPeriod ends", async function () {
            const { strategy, asset, manager, deployer, otherAccount } = await loadFixture(deployTFStrategyFixture);
    
            // Simulate the strategy investing funds
            const deployAmount = ethers.parseEther("100");
            await asset.approve(strategy.target, deployAmount);
            await strategy.deposit(deployAmount, deployer.address);

            // Approve the strategy to spend the asset on behalf of the manager
            await asset.connect(manager).approve(strategy.target, deployAmount);
    
            // Attempt to withdraw more than the manager's balance, expecting a revert
            const withdrawalAmount = ethers.parseEther("100");
            await expect(
                strategy.withdraw(withdrawalAmount, otherAccount.address, deployer.address)
            ).to.be.revertedWith("ERC4626: withdraw more than max");
        });
    });

    describe("_emergencyWithdraw()", function () {
        async function deployAndSetupScenario() {
            const { strategy, tfStrategy, asset, deployer, manager, otherAccount } = await loadFixture(deployTFStrategyFixture);
    
            // Simulate the strategy investing funds
            const deployAmount = ethers.parseEther("1000");
            await asset.mint(deployer.address, deployAmount);
            await asset.approve(strategy.target, deployAmount);
            await strategy.deposit(deployAmount, deployer.address);

            await asset.connect(manager).approve(strategy.target, deployAmount);
    
            return { strategy, tfStrategy, asset, manager, deployAmount, otherAccount };
        }
    
        it("Successfully performs emergency withdrawal after shutdown", async function () {
            const { strategy, tfStrategy, asset, deployAmount, manager } = await deployAndSetupScenario();
    
            // Authorize and shutdown the strategy
            await strategy.connect(manager).shutdownStrategy();

            const emergencyWithdrawAmount1 = ethers.parseEther("600");
            const expectedDebtAfterWithrawal1 = deployAmount - emergencyWithdrawAmount1;

            expect(await asset.balanceOf(strategy.target)).to.equal(0);

            // check initial TradeFintechStrategy accounting
            expect(await tfStrategy.totalInvested()).to.equal(deployAmount);    

            // check initial TokenizedStrategy accounting
            expect(await strategy.totalDebt()).to.equal(deployAmount);
            expect(await strategy.totalIdle()).to.equal(0);     
            expect(await strategy.totalAssets()).to.equal(deployAmount);
    
            // Eemergency withdrawal some amount           
            await strategy.connect(manager).emergencyWithdraw(emergencyWithdrawAmount1);
    
            // Verify funds were withdrawn
            expect(await asset.balanceOf(strategy.target)).to.equal(emergencyWithdrawAmount1);
    
            // Verify TradeFintechStrategy accounting
            expect(await tfStrategy.totalInvested()).to.equal(expectedDebtAfterWithrawal1);   

            // Verify TokenizedStrategy accounting
            expect(await strategy.totalDebt()).to.equal(expectedDebtAfterWithrawal1);
            expect(await strategy.totalIdle()).to.equal(emergencyWithdrawAmount1);     
            expect(await strategy.totalAssets()).to.equal(deployAmount);

            // Eemergency withdrawal the rest     
            await strategy.connect(manager).emergencyWithdraw(expectedDebtAfterWithrawal1);

            // Verify funds were withdrawn
            expect(await asset.balanceOf(strategy.target)).to.equal(deployAmount);
    
            // Verify TradeFintechStrategy accounting
            expect(await tfStrategy.totalInvested()).to.equal(0);   

            // Verify TokenizedStrategy accounting
            expect(await strategy.totalDebt()).to.equal(0);
            expect(await strategy.totalIdle()).to.equal(deployAmount);     
            expect(await strategy.totalAssets()).to.equal(deployAmount);
        });

        it("Handles withdrawal exceeding the current balance by withdrawing available", async function () {
            const { strategy, tfStrategy, asset, manager, deployAmount, otherAccount } = await deployAndSetupScenario();
    
            // Authorize and shutdown the strategy
            await strategy.connect(manager).connect(manager).shutdownStrategy();
    
            const expectedWithdrawal = ethers.parseEther("550");
            const managerBalance = await asset.balanceOf(manager.address);

            // reduce the balance of the manager
            await asset.connect(manager).transfer(otherAccount.address, managerBalance - expectedWithdrawal);

            // Attempt emergency withdrawal
            await strategy.connect(manager).emergencyWithdraw(deployAmount);
    
            // Verify funds were withdrawn
            expect(await asset.balanceOf(strategy.target)).to.equal(ethers.parseEther("550"));
    
            // Verify TradeFintechStrategy accounting
            expect(await tfStrategy.totalInvested()).to.equal(ethers.parseEther("450"));   

            // Verify TokenizedStrategy accounting
            expect(await strategy.totalDebt()).to.equal(ethers.parseEther("450"));
            expect(await strategy.totalIdle()).to.equal(ethers.parseEther("550"));     
            expect(await strategy.totalAssets()).to.equal(ethers.parseEther("1000"));
        });
    
        it("Reverts emergency withdrawal if strategy is not shutdown", async function () {
            const { strategy, manager } = await deployAndSetupScenario();
    
            // Attempt emergency withdrawal without shutting down the strategy
            await expect(
                strategy.connect(manager).emergencyWithdraw(ethers.parseEther("50"))
            ).to.be.revertedWith("not shutdown");
        });

        it("Reverts emergency withdrawal if caller is not manager", async function () {
            const { strategy, otherAccount } = await deployAndSetupScenario();
    
            // Attempt emergency withdrawal without shutting down the strategy
            await expect(
                strategy.connect(otherAccount).emergencyWithdraw(ethers.parseEther("50"))
            ).to.be.revertedWith("!emergency authorized");
        });
    });

    describe("lockFunds()", function () {
        async function deployAndSetupScenarioForLockingFunds() {
            const { strategy, asset, manager, deployer, otherAccount, tfStrategy, depositPeriodEnds } = await loadFixture(deployTFStrategyFixture);
    
            // Simulate the strategy deploying funds to the manager
            const idleAmount = ethers.parseEther("100");
            await asset.mint(strategy.target, idleAmount);

            await strategy.report();
    
            return { strategy, asset, manager, deployer, otherAccount, idleAmount, tfStrategy, depositPeriodEnds };
        }
    
        it("Reverts if not called by manager", async function () {
            const { tfStrategy, deployer } = await deployAndSetupScenarioForLockingFunds();
            const lockAmount = ethers.parseEther("10");

            await expect(tfStrategy.connect(deployer).lockFunds(lockAmount))
                .to.be.revertedWith("!management");
        });
    
        it("Reverts if attempting to lock 0 funds", async function () {
            const { tfStrategy, manager } = await deployAndSetupScenarioForLockingFunds();
    
            await expect(tfStrategy.connect(manager).lockFunds(0))
                .to.be.revertedWithCustomError(tfStrategy, "ZeroAmount");
        });

        it("Reverts if attempting to lock more than balance", async function () {
            const { tfStrategy, manager, idleAmount, depositPeriodEnds } = await deployAndSetupScenarioForLockingFunds();

            await time.increaseTo(depositPeriodEnds + 1);
    
            await expect(tfStrategy.connect(manager).lockFunds(idleAmount + BigInt(1)))
                .to.be.revertedWithCustomError(tfStrategy, "InsufficientFundsIdle");
        });

        it("Reverts if attempting to lock after lock period ends", async function () {
            const { tfStrategy, manager, idleAmount } = await deployAndSetupScenarioForLockingFunds();
    
            const lockPeriodEnds = await tfStrategy.lockPeriodEnds();
            await time.increaseTo(lockPeriodEnds + BigInt(1));
            
            await expect(tfStrategy.connect(manager).lockFunds(idleAmount))
                .to.be.revertedWithCustomError(tfStrategy, "LockPeriodEnded");
        });

        it("Successfully updates TF Strategy balance after funds return", async function () {
            const { tfStrategy, asset, manager, idleAmount, depositPeriodEnds } = await deployAndSetupScenarioForLockingFunds();
            const lockAmount = ethers.parseEther("50");
            
            // Simulate manager holding funds to return
            await asset.transfer(manager.address, lockAmount);
            await asset.connect(manager).approve(tfStrategy.target, lockAmount);

            await time.increaseTo(depositPeriodEnds + 1);

            await expect(
                tfStrategy.connect(manager).lockFunds(lockAmount)
            ).to.emit(tfStrategy, 'FundsLocked').withArgs(manager.address, lockAmount);
    
            const finalTFStrategyBalance = await asset.balanceOf(tfStrategy.target);
            expect(finalTFStrategyBalance).to.equal(idleAmount - lockAmount);
        });
    });

    describe("repay()", function () {
        async function deployAndSetupScenarioForReturningFunds() {
            const { strategy, asset, manager, deployer, otherAccount, tfStrategy, lockPeriodEnds } = await loadFixture(deployTFStrategyFixture);
    
            // Simulate the strategy deploying funds to the manager
            const depositAmount = ethers.parseEther("100");
            await asset.mint(deployer.address, depositAmount);
            await asset.approve(strategy.target, depositAmount);
            await strategy.deposit(depositAmount, deployer.address);

            await strategy.report();
    
            return { strategy, asset, manager, deployer, otherAccount, depositAmount, tfStrategy, lockPeriodEnds };
        }
    
        it("Reverts if not called by manager", async function () {
            const { tfStrategy, deployer } = await deployAndSetupScenarioForReturningFunds();
            const returnAmount = ethers.parseEther("10");

            await expect(tfStrategy.connect(deployer).repay(returnAmount))
                .to.be.revertedWith("!management");
        });
    
        it("Reverts if attempting to return 0 funds", async function () {
            const { tfStrategy, manager } = await deployAndSetupScenarioForReturningFunds();
    
            await expect(tfStrategy.connect(manager).repay(0))
                .to.be.revertedWithCustomError(tfStrategy, "ZeroAmount");
        });

        it("Reverts if repay before lock period ends", async function () {
            const { tfStrategy, manager, depositAmount } = await deployAndSetupScenarioForReturningFunds();

            await expect(tfStrategy.connect(manager).repay(depositAmount + BigInt(1)))
                .to.be.revertedWithCustomError(tfStrategy, "LockPeriodNotEnded");
        });

        it("Repay invested", async function () {
            const { asset, tfStrategy, manager, depositAmount, lockPeriodEnds } = await deployAndSetupScenarioForReturningFunds();

            const returnAmount = depositAmount;

            await time.increaseTo(lockPeriodEnds + 1);

            await asset.connect(manager).approve(tfStrategy.target, returnAmount);
    
            await expect(tfStrategy.connect(manager).repay(returnAmount))
                .to.emit(tfStrategy, 'FundsReturned')
                .withArgs(manager.address, returnAmount);
        });

        it("Report gain if repay more than invested", async function () {
            const { asset, tfStrategy, manager, depositAmount, lockPeriodEnds } = await deployAndSetupScenarioForReturningFunds();

            const gain = ethers.parseEther("10");
            const returnAmount = depositAmount + gain;

            await time.increaseTo(lockPeriodEnds + 1);

            await asset.mint(manager.address, gain);
            await asset.connect(manager).approve(tfStrategy.target, returnAmount);
    
            await expect(tfStrategy.connect(manager).repay(returnAmount))
                .to.emit(tfStrategy, 'GainReported')
                .withArgs(manager.address, gain);
        });

        it("Report loss if repay less than invested", async function () {
            const { asset, tfStrategy, manager, depositAmount, lockPeriodEnds } = await deployAndSetupScenarioForReturningFunds();

            const loss = ethers.parseEther("10");
            const returnAmount = depositAmount - loss;

            await time.increaseTo(lockPeriodEnds + 1);

            await asset.connect(manager).approve(tfStrategy.target, returnAmount);
    
            await expect(tfStrategy.connect(manager).repay(returnAmount))
                .to.emit(tfStrategy, 'LossReported')
                .withArgs(manager.address, loss);
        });

        it("Successfully updates TF Strategy balance after funds return", async function () {
            const { tfStrategy, asset, manager, lockPeriodEnds } = await deployAndSetupScenarioForReturningFunds();
            const returnAmount = ethers.parseEther("50");
            
            // Simulate manager holding funds to return
            await asset.transfer(manager.address, returnAmount);
            await asset.connect(manager).approve(tfStrategy.target, returnAmount);

            const initialTFStrategyBalance = await asset.balanceOf(tfStrategy.target);

            await time.increaseTo(lockPeriodEnds + 1);
    
            await expect(tfStrategy.connect(manager).repay(returnAmount))
                .to.emit(tfStrategy, 'FundsReturned')
                .withArgs(manager.address, returnAmount);
    
    
            const finalTFStrategyBalance = await asset.balanceOf(tfStrategy.target);
            expect(finalTFStrategyBalance).to.equal(initialTFStrategyBalance + returnAmount);
        });
    });

    describe("setDepositLimit()", function () {    
        it("Allows manager to set deposit limit", async function () {
            const { tfStrategy, manager } = await loadFixture(deployTFStrategyFixture);
            const depositLimit = ethers.parseEther("50");

            await tfStrategy.connect(manager).setDepositLimit(depositLimit);
    
            const newDepositLimit = await tfStrategy.depositLimit();
            expect(newDepositLimit).to.equal(depositLimit);
        });
    
        it("Reverts if not called by manager", async function () {
            const { tfStrategy, deployer } = await loadFixture(deployTFStrategyFixture);
            const depositLimit = ethers.parseEther("50");

            await expect(tfStrategy.connect(deployer).setDepositLimit(depositLimit))
                .to.be.revertedWith("!management");
        });
    
        it("Reverts if attempting to set 0 as new deposit limit", async function () {
            const { tfStrategy, manager } = await loadFixture(deployTFStrategyFixture);

            await expect(tfStrategy.connect(manager).setDepositLimit(0))
                .to.be.revertedWithCustomError(tfStrategy, "InvalidDepositLimit");
        });

        it("Reverts if attempting to set new deposit limit lower than total invested", async function () {
            const { asset, strategy, tfStrategy, manager, deployer } = await loadFixture(deployTFStrategyFixture);

            const depositAmount = ethers.parseEther("10000");
            await asset.mint(deployer.address, depositAmount);
            await asset.approve(strategy.target, depositAmount);
            await strategy.deposit(depositAmount, deployer.address);

            await expect(tfStrategy.connect(manager).setDepositLimit(depositAmount - BigInt(1)))
                .to.be.revertedWithCustomError(tfStrategy, "InvalidDepositLimit");
        });
    });    
});
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
    const depositPeriodEnds = 604800; // 1 week
    const lockPeriodEnds = 86400 * 30; // 30 days

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

    // Deploy TradeFintechStrategy
    const TFStrategy = await ethers.getContractFactory("TradeFintechStrategy");
    const tfStrategy = await TFStrategy.deploy(
        asset.target,
        "Trade Fintech Strategy",
        tokenizedStrategy.target,
        manager.address,
        depositPeriodEnds,
        lockPeriodEnds
    );

    const strategy = await ethers.getContractAt("TokenizedStrategy", tfStrategy.target);

    // Add Strategy to Vault
    await expect(vault.addStrategy(strategy.target))
        .to.emit(vault, 'StrategyChanged')
        .withArgs(strategy.target, 0);
    await expect(vault.updateMaxDebtForStrategy(strategy.target, amount))
        .to.emit(vault, 'UpdatedMaxDebtForStrategy')
        .withArgs(deployer.address, strategy.target, amount);

    return { vault, strategy, asset, deployer, manager, otherAccount, depositPeriodEnds, lockPeriodEnds };
}

describe("TradeFintechStrategy tests", function () {

    describe("TradeFintechStrategy init tests", function () {
        it("Initializes with correct parameters", async function () {
            const { strategy, manager, depositPeriodEnds } = await loadFixture(deployTFStrategyFixture);
            const TFStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);

            const latestBlock = await time.latestBlock();
            const latestBlockTimestamp = (await ethers.provider.getBlock(latestBlock)).timestamp;

            expect(await TFStrategy.managerAddress()).to.equal(manager.address);
            expect(await TFStrategy.depositPeriodEnds()).to.be.lessThanOrEqual(latestBlockTimestamp + depositPeriodEnds);
        });
    });

    describe("_harvestAndReport()", function () {
        it("Correctly transfer funds to manager and reports total assets", async function () {
            const { strategy, asset, manager } = await loadFixture(deployTFStrategyFixture);

            const depositAmount = ethers.parseEther("100");
    
            await asset.transfer(strategy.target, depositAmount);
            await strategy.report();

            const TFStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
            const totalAssets = await TFStrategy.totalInvestedInRWA();
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
            const { strategy, deployer } = await loadFixture(deployTFStrategyFixture);
            
            const TFStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
            const availableLimit = await TFStrategy.availableDepositLimit(deployer.address);
            expect(availableLimit).to.equal(ethers.MaxUint256);
        });
    
        it("Correctly reduces the available deposit limit based on the contract's balance", async function () {
            const { strategy, asset, deployer } = await loadFixture(deployTFStrategyFixture);

            const depositAmount = ethers.parseEther("100");
    
            // Simulate the contract holding some amount of the asset tokens
            await asset.transfer(strategy.target, depositAmount);
    
            const TFStrategy = await ethers.getContractAt("TradeFintechStrategy", strategy.target);
            const availableLimit = await TFStrategy.availableDepositLimit(deployer.address);
            const expectedLimit = ethers.MaxUint256 - depositAmount;
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
            const totalInvestedInRWA = await tfStrategy.totalInvestedInRWA();
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
            const totalInvestedInRWA = await TFStrategy.totalInvestedInRWA();
            expect(totalInvestedInRWA).to.equal(0);
        });
    });

    // describe("_freeFunds()", function () {
    //     it("Successfully transfers funds and updates totalInvestedInRWA on withdrawal", async function () {
    //         const { vault, strategy, asset, manager, deployer, otherAccount } = await loadFixture(deployRWAStrategyFixture);
            
    //         // Simulate the strategy investing funds
    //         const deployAmount = 2000;
    //         await asset.approve(vault.target, deployAmount);
    //         await vault.setDepositLimit(deployAmount);
    //         await vault.deposit(deployAmount, deployer.address);

    //         await expect(vault.updateMaxDebtForStrategy(strategy.target, deployAmount))
    //             .to.emit(vault, 'UpdatedMaxDebtForStrategy')
    //             .withArgs(deployer.address, strategy.target, deployAmount);
            
    //         await vault.updateDebt(strategy.target, deployAmount);

    //         // Approve the strategy to spend the asset on behalf of the manager
    //         await asset.connect(manager).approve(strategy.target, deployAmount);
    
    //         // Perform withdrawal through the vault, triggering _freeFunds
    //         const withdrawalAmount = 50;
    //         await vault.withdraw(
    //             withdrawalAmount,
    //             otherAccount.address, // receiver
    //             deployer.address, // owner
    //             0,
    //             []
    //         );
    
    //         // Verify funds are transferred back to the user from the manager through the strategy
    //         const strategyBalanceAfter = await asset.balanceOf(otherAccount.address);
    //         expect(strategyBalanceAfter).to.equal(withdrawalAmount);
    
    //         // Verify totalInvestedInRWA is updated correctly
    //         const rwaStrategy = await ethers.getContractAt("RWAStrategy", strategy.target);
    //         const totalInvestedAfter = await rwaStrategy.totalInvestedInRWA();
    //         const expectedInvestedAfter = deployAmount - withdrawalAmount;
    //         expect(totalInvestedAfter).to.equal(expectedInvestedAfter);
    //     });
    
    //     it("Reverts withdrawal if attempting to free more funds than available", async function () {
    //         const { vault, strategy, asset, manager, deployer, otherAccount } = await loadFixture(deployRWAStrategyFixture);
    
    //         // Simulate the strategy investing funds
    //         const deployAmount = 2000;
    //         await asset.approve(vault.target, deployAmount);
    //         await vault.setDepositLimit(deployAmount);
    //         await vault.deposit(deployAmount, deployer.address);

    //         await expect(vault.updateMaxDebtForStrategy(strategy.target, deployAmount))
    //             .to.emit(vault, 'UpdatedMaxDebtForStrategy')
    //             .withArgs(deployer.address, strategy.target, deployAmount);
            
    //         await vault.updateDebt(strategy.target, deployAmount);

    //         // Approve the strategy to spend the asset on behalf of the manager
    //         await asset.connect(manager).approve(strategy.target, deployAmount);

    //         // Fake manager buying some RWA
    //         await asset.connect(manager).transfer(otherAccount.address, deployAmount);
    
    //         // Attempt to withdraw more than the manager's balance, expecting a revert
    //         const withdrawalAmount = 2000; // More than manager's balance
    //         await expect(vault.withdraw(
    //             withdrawalAmount,
    //             otherAccount.address, // receiver
    //             deployer.address, // owner
    //             0,
    //             [] // Adjust based on actual parameters
    //         )).to.be.revertedWith("ERC20: transfer amount exceeds balance");
    //     });
    // });

    // describe("_emergencyWithdraw()", function () {
    //     async function deployAndSetupScenario() {
    //         const { vault, strategy, asset, deployer, manager, otherAccount } = await loadFixture(deployRWAStrategyFixture);
    
    //         // Simulate the strategy investing funds
    //         const deployAmount = 2000;
    //         const emergencyWithdrawAmount = 500;
    //         await asset.approve(vault.target, deployAmount);
    //         await vault.setDepositLimit(deployAmount);
    //         await vault.deposit(deployAmount, deployer.address);

    //         await expect(vault.updateMaxDebtForStrategy(strategy.target, deployAmount))
    //             .to.emit(vault, 'UpdatedMaxDebtForStrategy')
    //             .withArgs(deployer.address, strategy.target, deployAmount);

    //         await vault.updateDebt(strategy.target, deployAmount);
    //         await asset.connect(manager).approve(strategy.target, deployAmount);
    
    //         return { strategy, asset, manager, deployAmount, emergencyWithdrawAmount, otherAccount };
    //     }
    
    //     it("Successfully performs emergency withdrawal after shutdown", async function () {
    //         const { strategy, asset, manager, deployAmount, emergencyWithdrawAmount } = await deployAndSetupScenario();
    
    //         // Authorize and shutdown the strategy
    //         await strategy.shutdownStrategy();
    
    //         // Attempt emergency withdrawal            
    //         await strategy.emergencyWithdraw(emergencyWithdrawAmount);
    
    //         // Verify funds were transferred from manager to strategy
    //         const finalStrategyBalance = await asset.balanceOf(strategy.target);
    //         expect(finalStrategyBalance).to.equal(emergencyWithdrawAmount);
    
    //         // Verify internal accounting
    //         const rwaStrategy = await ethers.getContractAt("RWAStrategy", strategy.target);
    //         const totalInvestedAfterWithdraw = await rwaStrategy.totalInvestedInRWA();
    //         expect(totalInvestedAfterWithdraw).to.equal(deployAmount - emergencyWithdrawAmount);
    //     });
    
    //     it("Reverts emergency withdrawal if strategy is not shutdown", async function () {
    //         const { strategy, emergencyWithdrawAmount } = await deployAndSetupScenario();
    
    //         // Attempt emergency withdrawal without shutting down the strategy
    //         await expect(
    //             strategy.emergencyWithdraw(emergencyWithdrawAmount)
    //         ).to.be.revertedWith("not shutdown");
    //     });

    //     it("Reverts emergency withdrawal if caller is not manager", async function () {
    //         const { strategy, emergencyWithdrawAmount, otherAccount } = await deployAndSetupScenario();
    
    //         // Attempt emergency withdrawal without shutting down the strategy
    //         await expect(
    //             strategy.connect(otherAccount).emergencyWithdraw(emergencyWithdrawAmount)
    //         ).to.be.revertedWith("!emergency authorized");
    //     });
    // });

    // describe("setMinAmountToSell()", function () {    
    //     it("Allows management to update minAmountToSell", async function () {
    //         const { strategy, manager } = await loadFixture(deployRWAStrategyFixture);
    //         const newMinAmount = 500;
    
    //         const rwaStrategy = await ethers.getContractAt("RWAStrategy", strategy.target);

    //         await rwaStrategy.setMinAmountToSell(newMinAmount);
    
    //         const updatedMinAmount = await rwaStrategy.minAmountToSell();
    //         expect(updatedMinAmount).to.equal(newMinAmount);
    //     });
    
    //     it("Reverts when a non-management user tries to update minAmountToSell", async function () {
    //         const { strategy, otherAccount } = await loadFixture(deployRWAStrategyFixture);
    //         const newMinAmount = 500;

    //         const rwaStrategy = await ethers.getContractAt("RWAStrategy", strategy.target);
    
    //         await expect(rwaStrategy.connect(otherAccount).setMinAmountToSell(newMinAmount))
    //             .to.be.revertedWith("!management");
    //     });
    // });
});
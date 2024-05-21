const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("setStrategyManager", function () {
    let liquidationStrategy;
    let owner, newManager, unauthorizedAddress;

    beforeEach(async function () {
        // Get signers
        [owner, newManager, unauthorizedAddress] = await ethers.getSigners();
        // Deploy a mock ERC20 token to use as the asset
        const MockERC20 = await ethers.getContractFactory("Token");
        asset = await MockERC20.deploy("FXD", 18);
        await asset.waitForDeployment();
        await new Promise(resolve => setTimeout(resolve, 1000));
        // Assign addresses to other constructor parameters, reusing where necessary
        tokenizedStrategyAddress = newManager.address;
        strategyManager = owner.address;
        fixedSpreadLiquidationStrategy = newManager.address; // Reusing newManager for another role
        bookKeeper = unauthorizedAddress.address; // Reusing unauthorizedAddress for another role
        stablecoinAdapter = newManager.address; // Reusing newManager again

        // Deploy the LiquidationStrategy contract
        LiquidationStrategy = await ethers.getContractFactory("LiquidationStrategy");
        liquidationStrategy = await LiquidationStrategy.deploy(
            asset.target,
            "Liquidation Strategy",
            tokenizedStrategyAddress,
            strategyManager,
            fixedSpreadLiquidationStrategy,
            bookKeeper,
            stablecoinAdapter
        );
        await liquidationStrategy.waitForDeployment();
    });

    it("Should only allow the current strategy manager to update the strategy manager address", async function () {
        // Initially, the owner is the strategy manager. Attempt to set the strategy manager from an unauthorized address.
        await expect(liquidationStrategy.connect(unauthorizedAddress).setStrategyManager(newManager.address))
            .to.be.revertedWithCustomError(liquidationStrategy, "NotStrategyManager"); // Adjust the revert message to match your contract

        // Now, let the current strategy manager (owner) update the strategy manager to `newManager`.
        await expect(liquidationStrategy.connect(owner).setStrategyManager(newManager.address))
            .to.not.be.reverted; // This should succeed
    });

    it("Should emit LogSetStrategyManager with correct parameters", async function () {
        await expect(liquidationStrategy.connect(owner).setStrategyManager(newManager.address))
            .to.emit(liquidationStrategy, "LogSetStrategyManager")
            .withArgs(newManager.address); // This tests the event and its parameters
    });

    it("Should revert when called with a zero address", async function () {
        await expect(liquidationStrategy.connect(owner).setStrategyManager(ethers.ZeroAddress))
            .to.be.revertedWithCustomError(liquidationStrategy, "ZeroAddress"); // Adjust the revert message to match your contract
    });

    it("Should revert when setting the same strategy manager address", async function () {
        // Attempt to set the current strategy manager (owner) as the strategy manager again
        await expect(liquidationStrategy.connect(owner).setStrategyManager(owner.address))
            .to.be.revertedWithCustomError(liquidationStrategy, "SameStrategyManager"); // Adjust the revert message to match your contract
    });
});


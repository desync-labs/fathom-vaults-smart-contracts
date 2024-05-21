const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("setFixedSpreadLiquidationStrategy", function () {
    let liquidationStrategy;
    let owner, newLiquidationStrategy, unauthorizedAddress;
    let asset;

    beforeEach(async function () {
        [owner, newLiquidationStrategy, unauthorizedAddress] = await ethers.getSigners();
        const MockERC20 = await ethers.getContractFactory("Token");
        asset = await MockERC20.deploy("FXD", 18);
        await asset.waitForDeployment();
        await new Promise(resolve => setTimeout(resolve, 1000));
        // Additional setup omitted for brevity
        // Assume liquidationStrategy is deployed here and ready for testing

        const LiquidationStrategy = await ethers.getContractFactory("LiquidationStrategy");
        liquidationStrategy = await LiquidationStrategy.deploy(
            asset.target, // asset
            "Liquidation Strategy", // name
            owner.address, // tokenizedStrategyAddress
            owner.address, // strategyManager
            owner.address, // fixedSpreadLiquidationStrategy initially set to owner for simplicity
            owner.address, // bookKeeper
            owner.address  // stablecoinAdapter
        );
        await liquidationStrategy.waitForDeployment();
        
    });

    it("Should only allow the current strategy manager to update the fixed spread liquidation strategy address", async function () {
        await expect(liquidationStrategy.connect(unauthorizedAddress).setFixedSpreadLiquidationStrategy(newLiquidationStrategy.address))
            .to.be.revertedWithCustomError(liquidationStrategy, "NotStrategyManager");

        await expect(liquidationStrategy.connect(owner).setFixedSpreadLiquidationStrategy(newLiquidationStrategy.address))
            .to.not.be.reverted;
    });

    it("Should emit LogSetFixedSpreadLiquidationStrategy with correct parameters", async function () {
        await expect(liquidationStrategy.connect(owner).setFixedSpreadLiquidationStrategy(newLiquidationStrategy.address))
            .to.emit(liquidationStrategy, "LogSetFixedSpreadLiquidationStrategy")
            .withArgs(newLiquidationStrategy.address);
    });

    it("Should revert when called with a zero address", async function () {
        await expect(liquidationStrategy.connect(owner).setFixedSpreadLiquidationStrategy(ethers.ZeroAddress))
            .to.be.revertedWithCustomError(liquidationStrategy, "ZeroAddress");
    });

    it("Should revert when setting the same fixed spread liquidation strategy address", async function () {
        await expect(liquidationStrategy.connect(owner).setFixedSpreadLiquidationStrategy(owner.address)) // Assuming owner is the initial fixedSpreadLiquidationStrategy for simplicity
            .to.be.revertedWithCustomError(liquidationStrategy, "SameFixedSpreadLiquidationStrategy");
    });
});

const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("setUSDTInPath", function () {
    let liquidationStrategy;
    let owner, addr1, newUSDTAddress;
    let asset;

    beforeEach(async function () {
        [owner, addr1, newUSDTAddress] = await ethers.getSigners();

        const MockERC20 = await ethers.getContractFactory("Token");
        asset = await MockERC20.deploy("FXD", 18);
        await asset.waitForDeployment();
        await new Promise(resolve => setTimeout(resolve, 1000));

        const LiquidationStrategy = await ethers.getContractFactory("LiquidationStrategy");
        liquidationStrategy = await LiquidationStrategy.deploy(
            asset.target,
            "Liquidation Strategy",
            owner.address, // TokenizedStrategyAddress
            owner.address, // StrategyManager
            owner.address, // FixedSpreadLiquidationStrategy
            owner.address, // BookKeeper
            owner.address  // StablecoinAdapter
        );
        await liquidationStrategy.waitForDeployment();
    });

    it("Should only allow the current strategy manager to set the USDT address", async function () {
        await expect(liquidationStrategy.connect(addr1).setUSDTInPath(newUSDTAddress.address))
            .to.be.revertedWithCustomError(liquidationStrategy, "NotStrategyManager");

        await expect(liquidationStrategy.connect(owner).setUSDTInPath(newUSDTAddress.address))
            .to.not.be.reverted;
    });

    it("Should emit LogSetUSDTInPath with the correct parameters when the USDT address is set", async function () {
        await expect(liquidationStrategy.connect(owner).setUSDTInPath(newUSDTAddress.address))
            .to.emit(liquidationStrategy, "LogSetUSDTInPath")
            .withArgs(newUSDTAddress.address);
    });

    it("Should revert when called with a zero address", async function () {
        await expect(liquidationStrategy.connect(owner).setUSDTInPath(ethers.ZeroAddress))
            .to.be.revertedWithCustomError(liquidationStrategy, "ZeroAddress");
    });
});

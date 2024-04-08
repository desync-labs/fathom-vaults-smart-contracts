const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("setV3Info", function () {
    let liquidationStrategy;
    let owner, addr1;
    let asset, permit2Address, universalRouterAddress, invalidAddress = ethers.ZeroAddress;
    let poolFee = 3000; // Example fee

    beforeEach(async function () {
        [owner, addr1, addr2] = await ethers.getSigners();
        permit2Address = addr1.address; // Assuming addr1 and addr2 are mock addresses for testing
        universalRouterAddress = addr1.address; // Reusing addr1 for simplicity, replace as needed

        const MockERC20 = await ethers.getContractFactory("Token");
        asset = await MockERC20.deploy("FXD", 18);
        await new Promise(resolve => setTimeout(resolve, 1000));

        const LiquidationStrategy = await ethers.getContractFactory("LiquidationStrategy");
        liquidationStrategy = await LiquidationStrategy.deploy(
            asset.target, // Asset
            "Liquidation Strategy", // Name
            owner.address, // TokenizedStrategyAddress
            owner.address, // StrategyManager
            owner.address, // FixedSpreadLiquidationStrategy
            owner.address, // BookKeeper
            owner.address  // StablecoinAdapter
        );
    });

    it("Should only allow the current strategy manager to update the V3 information", async function () {
        await expect(
            liquidationStrategy.connect(addr1).setV3Info(permit2Address, universalRouterAddress, poolFee)
        ).to.be.revertedWithCustomError(liquidationStrategy, "NotStrategyManager");

        await expect(
            liquidationStrategy.connect(owner).setV3Info(permit2Address, universalRouterAddress, poolFee)
        ).to.not.be.reverted;
    });

    it("Should emit LogSetV3Info with correct parameters", async function () {
        await expect(liquidationStrategy.connect(owner).setV3Info(permit2Address, universalRouterAddress, poolFee))
            .to.emit(liquidationStrategy, "LogSetV3Info")
            .withArgs(permit2Address, universalRouterAddress);
    });

    it("Should revert when called with a zero address for permit2", async function () {
        await expect(
            liquidationStrategy.connect(owner).setV3Info(invalidAddress, universalRouterAddress, poolFee)
        ).to.be.revertedWithCustomError(liquidationStrategy, "ZeroAddress");
    });

    it("Should revert when called with a zero address for universalRouter", async function () {
        await expect(
            liquidationStrategy.connect(owner).setV3Info(permit2Address, invalidAddress, poolFee)
        ).to.be.revertedWithCustomError(liquidationStrategy, "ZeroAddress");
    });

    it("Should revert when setting the same V3 information again", async function () {
        // First set to valid information
        await liquidationStrategy.connect(owner).setV3Info(permit2Address, universalRouterAddress, poolFee);

        // Attempt to set the same information again
        await expect(
            liquidationStrategy.connect(owner).setV3Info(permit2Address, universalRouterAddress, poolFee)
        ).to.be.revertedWithCustomError(liquidationStrategy, "SameV3Info"); // Assuming your contract checks for no-ops
    });

    it("Should revert when called with a zero poolFee", async function () {
        await expect(
            liquidationStrategy.connect(owner).setV3Info(permit2Address, universalRouterAddress, 0)
        ).to.be.revertedWithCustomError(liquidationStrategy, "ZeroAmount");
    });    

    it("Should successfully update V3 info when setting different valid information", async function () {
        // First set to initial valid information
        await liquidationStrategy.connect(owner).setV3Info(permit2Address, universalRouterAddress, poolFee);

        // Set to new valid information
        let newPermit2Address = addr2.address; // Using addr2 for new permit2Address for differentiation
        let newUniversalRouterAddress = addr1.address; // Using addr1 for new universalRouterAddress for differentiation
        let newValidPoolFee = 5000; // New pool fee for differentiation

        await expect(
            liquidationStrategy.connect(owner).setV3Info(newPermit2Address, newUniversalRouterAddress, newValidPoolFee)
        ).to.emit(liquidationStrategy, "LogSetV3Info")
         .withArgs(newPermit2Address, newUniversalRouterAddress); // Check for correct event emission with new info
    });
});


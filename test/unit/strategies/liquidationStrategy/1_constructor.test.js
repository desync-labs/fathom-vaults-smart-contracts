const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LiquidationStrategy", function () {
    let LiquidationStrategy, liquidationStrategy;
    let owner, addr1, addr2;
    let asset, tokenizedStrategyAddress, strategyManager, fixedSpreadLiquidationStrategy, bookKeeper, stablecoinAdapter;

    beforeEach(async function () {
        // Get signers
        [owner, addr1, addr2] = await ethers.getSigners();
        // Deploy a mock ERC20 token to use as the asset
        const MockERC20 = await ethers.getContractFactory("Token");
        asset = await MockERC20.deploy("FXD", 18);
        await asset.waitForDeployment();
        await new Promise(resolve => setTimeout(resolve, 1000));

        // Assign addresses to other constructor parameters, reusing where necessary
        tokenizedStrategyAddress = addr1.address;
        strategyManager = addr2.address;
        fixedSpreadLiquidationStrategy = addr1.address; // Reusing addr1 for another role
        bookKeeper = addr2.address; // Reusing addr2 for another role
        stablecoinAdapter = addr1.address; // Reusing addr1 again

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
    });

    describe("Deployment", function () {
        it("Should set the right asset", async function () {
            expect(await liquidationStrategy.fathomStablecoin()).to.equal(asset.target);
        });

        it("Should set the right tokenizedStrategyAddress", async function () {
            expect(await liquidationStrategy.tokenizedStrategyAddress()).to.equal(tokenizedStrategyAddress);
        });

        it("Should set the right strategyManager", async function () {
            expect(await liquidationStrategy.strategyManager()).to.equal(strategyManager);
        });

        it("Should set the right fixedSpreadLiquidationStrategy", async function () {
            expect(await liquidationStrategy.fixedSpreadLiquidationStrategy()).to.equal(fixedSpreadLiquidationStrategy);
        });

        it("Should set the right bookKeeper", async function () {
            expect(await liquidationStrategy.bookKeeper()).to.equal(bookKeeper);
        });

        it("Should set the right stablecoinAdapter", async function () {
            expect(await liquidationStrategy.stablecoinAdapter()).to.equal(stablecoinAdapter);
        });
    });
});

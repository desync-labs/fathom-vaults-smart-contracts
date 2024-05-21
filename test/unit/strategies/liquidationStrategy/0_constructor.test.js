const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LiquidationStrategy", function () {
    let LiquidationStrategy;
    let owner, addr1, addr2;
    let asset;

    beforeEach(async function () {
        [owner, addr1, addr2] = await ethers.getSigners();
        const MockERC20 = await ethers.getContractFactory("Token");
        asset = await MockERC20.deploy("FXD", 18);
        await asset.waitForDeployment();
        LiquidationStrategy = await ethers.getContractFactory("LiquidationStrategy");
        // make a delay here below
        await new Promise(resolve => setTimeout(resolve, 1000));
    });

    describe("Deployment with invalid inputs", function () {
        it("Should fail with zero address for the strategyManager parameter", async function () {
            await expect(
                LiquidationStrategy.deploy(
                    asset.target,
                    "Liquidation Strategy",
                    addr1.address,
                    ethers.ZeroAddress, // strategyManager set to zero address
                    addr1.address,
                    addr2.address,
                    addr1.address
                )
            ).to.be.revertedWithCustomError(LiquidationStrategy, "ZeroAddress");
        });

        it("Should fail with zero address for the fixedSpreadLiquidationStrategy parameter", async function () {
            await expect(
                LiquidationStrategy.deploy(
                    asset.target,
                    "Liquidation Strategy",
                    addr1.address,
                    addr2.address,
                    ethers.ZeroAddress, // fixedSpreadLiquidationStrategy set to zero address
                    addr2.address,
                    addr1.address
                )
            ).to.be.revertedWithCustomError(LiquidationStrategy, "ZeroAddress");
        });

        it("Should fail with zero address for the bookKeeper parameter", async function () {
            await expect(
                LiquidationStrategy.deploy(
                    asset.target,
                    "Liquidation Strategy",
                    addr1.address,
                    addr2.address,
                    addr1.address,
                    ethers.ZeroAddress, // bookKeeper set to zero address
                    addr1.address
                )
            ).to.be.revertedWithCustomError(LiquidationStrategy, "ZeroAddress");
        });

        it("Should fail with zero address for the stablecoinAdapter parameter", async function () {
            await expect(
                LiquidationStrategy.deploy(
                    asset.target,
                    "Liquidation Strategy",
                    addr1.address,
                    addr2.address,
                    addr1.address,
                    addr2.address,
                    ethers.ZeroAddress // stablecoinAdapter set to zero address
                )
            ).to.be.revertedWithCustomError(LiquidationStrategy, "ZeroAddress");
        });

        // Assuming tokenizedStrategyAddress must also not be a zero address.
        it("Should fail with zero address for the tokenizedStrategyAddress parameter", async function () {
            await expect(
                LiquidationStrategy.deploy(
                    asset.target,
                    "Liquidation Strategy",
                    ethers.ZeroAddress, // tokenizedStrategyAddress set to zero address
                    addr2.address,
                    addr1.address,
                    addr2.address,
                    addr1.address
                )
            ).to.be.revertedWithCustomError(LiquidationStrategy, "ZeroAddress");
        });

        // Assuming the asset (fathomStablecoin in this case) must also not be a zero address.
        it("Should fail with zero address for the asset parameter", async function () {
            await expect(
                LiquidationStrategy.deploy(
                    ethers.ZeroAddress, // asset set to zero address
                    "Liquidation Strategy",
                    addr1.address,
                    addr2.address,
                    addr1.address,
                    addr2.address,
                    addr1.address
                )
            ).to.be.revertedWithCustomError(LiquidationStrategy, "ZeroAddress");
        });
    });
});


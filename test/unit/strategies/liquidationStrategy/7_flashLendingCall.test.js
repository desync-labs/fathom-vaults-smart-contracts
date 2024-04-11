const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LiquidationStrategy - flashLendingCall", function () {
    let liquidationStrategy;
    let mockERC20Collateral, mockERC20FXD, mockUniswapV2Router, mockTokenAdapter;
    let owner, otherAccount2, otherAccount;

    beforeEach(async function () {
        [owner, otherAccount, otherAccount2] = await ethers.getSigners();

        // Mock ERC20 tokens
        const MockERC20 = await ethers.getContractFactory("Token");
        mockERC20Collateral = await MockERC20.deploy("Mock Collateral Token", 18);
        await mockERC20Collateral.waitForDeployment();

        mockERC20FXD = await MockERC20.deploy("FXD Stablecoin", 18);

        const MockBookKeeper = await ethers.getContractFactory("MockBookKeeper");
        mockBookKeeper = await MockBookKeeper.deploy();
        await mockBookKeeper.waitForDeployment();

        const MockStablecoinAdapter = await ethers.getContractFactory("MockStablecoinAdapter");
        mockStablecoinAdapter = await MockStablecoinAdapter.deploy(mockERC20FXD.target);
        await mockStablecoinAdapter.waitForDeployment();     

        // Deploy LiquidationStrategy with mocks
        const LiquidationStrategy = await ethers.getContractFactory("LiquidationStrategy");
        liquidationStrategy = await LiquidationStrategy.deploy(
            mockERC20FXD.target, // fathomStablecoin
            "Liquidation Strategy",
            owner.address, // tokenizedStrategyAddress
            owner.address, // strategyManager
            owner.address, // fixedSpreadLiquidationStrategy
            mockBookKeeper.target, // bookKeeper
            mockStablecoinAdapter.target  // stablecoinAdapter
        );
        await liquidationStrategy.waitForDeployment();
        // Mock UniswapV2Router and GenericTokenAdapter
        const MockUniswapV2Router = await ethers.getContractFactory("MockUniswapV2Router");
        mockUniswapV2Router = await MockUniswapV2Router.deploy(mockERC20Collateral.target, mockERC20FXD.target);
        await mockUniswapV2Router.waitForDeployment
        const MockCollateralTokenAdapter = await ethers.getContractFactory("MockCollateralTokenAdapter");
        mockTokenAdapter = await MockCollateralTokenAdapter.deploy(mockERC20Collateral.target);
        await mockTokenAdapter.waitForDeployment();
        await mockERC20Collateral.mint(mockTokenAdapter.target, ethers.parseEther("1000000"));
        await mockERC20FXD.mint(mockUniswapV2Router.target, ethers.parseEther("1000000"));
        await mockUniswapV2Router.setAmountsOut(ethers.parseEther("500"));
    });
    context("When not rightaway selling collateral", function () {
        it("should revert when called callable none fixedSpreadLiquidationStrategy address", async function () {
            const abiEncoder = new ethers.AbiCoder;
            const callData = abiEncoder.encode(
                ["address", "address", "address", "address", "uint256"],
                [otherAccount.address, mockTokenAdapter.target, ethers.ZeroAddress, ethers.ZeroAddress, 10000]
            );

            await expect(liquidationStrategy.connect(otherAccount).flashLendingCall(
                owner.address, ethers.parseEther("1000"), ethers.parseEther("500"), callData
            )).to.be.revertedWithCustomError(liquidationStrategy, "NotFixedSpreadLiquidationStrategy");
        });
        it("should work when called by the fixedSpreadLiquidationStrategy", async function () {
            const abiEncoder = new ethers.AbiCoder;
            const callData = abiEncoder.encode(
                ["address", "address", "address", "address", "uint256"],
                [otherAccount.address, mockTokenAdapter.target, ethers.ZeroAddress, ethers.ZeroAddress, 10000]
            );
            await mockERC20FXD.mint(liquidationStrategy.target, ethers.parseEther("1000000"));
            await expect(liquidationStrategy.connect(owner).flashLendingCall(
                owner.address, ethers.parseEther("1000"), ethers.parseEther("500"), callData
            )).not.to.be.reverted;
        });
        it("should revert when there is not enough FXD after selling collateral", async function () {
            const abiEncoder = new ethers.AbiCoder;
            const callData = abiEncoder.encode(
                ["address", "address", "address", "address", "uint256"],
                [otherAccount.address, mockTokenAdapter.target, ethers.ZeroAddress, ethers.ZeroAddress, 10000]
            );
            await expect(liquidationStrategy.connect(owner).flashLendingCall(
                owner.address, ethers.parseEther("1000"), ethers.parseEther("500"), callData
            )).to.be.revertedWithCustomError(liquidationStrategy, "NotEnoughToRepayDebt");
        });
        it("should emit LogFlashLiquidationSuccess after flashLendingCall", async function () {
            const abiEncoder = new ethers.AbiCoder;
            const callData = abiEncoder.encode(
                ["address", "address", "address", "address", "uint256"],
                [otherAccount.address, mockTokenAdapter.target, ethers.ZeroAddress, ethers.ZeroAddress, 10000]
            );
            await mockERC20FXD.mint(liquidationStrategy.target, ethers.parseEther("1000000"));
            await expect(liquidationStrategy.connect(owner).flashLendingCall(
                owner.address, ethers.parseEther("1000"), ethers.parseEther("500"), callData
            ))
            .to.emit(liquidationStrategy, "LogFlashLiquidationSuccess");
        });
        it("should not emit LogProfitOrLoss after flashLendingCall finishes", async function () {
            const abiEncoder = new ethers.AbiCoder;
            const callData = abiEncoder.encode(
                ["address", "address", "address", "address", "uint256"],
                [otherAccount.address, mockTokenAdapter.target, ethers.ZeroAddress, ethers.ZeroAddress, 10000]
            );
            await mockERC20FXD.mint(liquidationStrategy.target, ethers.parseEther("1000000"));
            await expect(liquidationStrategy.connect(owner).flashLendingCall(
                owner.address, ethers.parseEther("1000"), ethers.parseEther("500"), callData
            ))
            .not.to.emit(liquidationStrategy, "LogProfitOrLoss");
        });
        it("should set proper values to idleCollateral after flashLendingCall finishes", async function () {
            const abiEncoder = new ethers.AbiCoder;
            const callData = abiEncoder.encode(
                ["address", "address", "address", "address", "uint256"],
                [otherAccount.address, mockTokenAdapter.target, ethers.ZeroAddress, ethers.ZeroAddress, 10000]
            );
            await mockERC20FXD.mint(liquidationStrategy.target, ethers.parseEther("10000000000000000000000000000000"));
            let bigNumberString = `1${'0'.repeat(45)}`; // Creates the string "100" followed by 45 zeros
            await liquidationStrategy.connect(owner).flashLendingCall(
                owner.address, ethers.parseEther(bigNumberString), ethers.parseEther("500"), callData
            );
            const idleCollateral = await liquidationStrategy.idleCollateral(mockERC20Collateral.target);
            expect(await idleCollateral[0]).to.equal(500000000000000000000n);
            expect(await idleCollateral[1]).to.equal(1000000000000000000000000000000000001n);
            expect(await idleCollateral[2]).to.equal(2000000000000000000000000000000000n);
        });
    });
    context("When rightaway selling collateral", function () {
        it("should revert when called callable none fixedSpreadLiquidationStrategy address", async function () {
            const abiEncoder = new ethers.AbiCoder;
            const callData = abiEncoder.encode(
                ["address", "address", "address", "address", "uint256"],
                [otherAccount.address, mockTokenAdapter.target, mockUniswapV2Router.target, ethers.ZeroAddress, 10000]
            );

            await expect(liquidationStrategy.connect(otherAccount).flashLendingCall(
                owner.address, ethers.parseEther("1000"), ethers.parseEther("500"), callData
            )).to.be.revertedWithCustomError(liquidationStrategy, "NotFixedSpreadLiquidationStrategy");
        });
        it("should work when called by the fixedSpreadLiquidationStrategy", async function () {
            const abiEncoder = new ethers.AbiCoder;
            const callData = abiEncoder.encode(
                ["address", "address", "address", "address", "uint256"],
                [otherAccount.address, mockTokenAdapter.target, mockUniswapV2Router.target, ethers.ZeroAddress, 10000]
            );
            await mockERC20FXD.mint(liquidationStrategy.target, ethers.parseEther("1000000"));
            await expect(liquidationStrategy.connect(owner).flashLendingCall(
                owner.address, ethers.parseEther("1000"), ethers.parseEther("500"), callData
            )).not.to.be.reverted;
        });
        it("should revert when there is not enough FXD after selling collateral", async function () {
            const abiEncoder = new ethers.AbiCoder;
            const callData = abiEncoder.encode(
                ["address", "address", "address", "address", "uint256"],
                [otherAccount.address, mockTokenAdapter.target, mockUniswapV2Router.target, ethers.ZeroAddress, 10000]
            );
            await mockUniswapV2Router.setGiveLessFXD(true);
            await expect(liquidationStrategy.connect(owner).flashLendingCall(
                owner.address, ethers.parseEther("1000"), ethers.parseEther("1000"), callData
            )).to.be.revertedWithCustomError(liquidationStrategy, "NotEnoughToRepayDebt");
        });
        it("should emit LogFlashLiquidationSuccess after flashLendingCall", async function () {
            const abiEncoder = new ethers.AbiCoder;
            const callData = abiEncoder.encode(
                ["address", "address", "address", "address", "uint256"],
                [otherAccount.address, mockTokenAdapter.target, mockUniswapV2Router.target, ethers.ZeroAddress, 10000]
            );
            await mockERC20FXD.mint(liquidationStrategy.target, ethers.parseEther("1000000"));
            await expect(liquidationStrategy.connect(owner).flashLendingCall(
                owner.address, ethers.parseEther("1000"), ethers.parseEther("500"), callData
            ))
            .to.emit(liquidationStrategy, "LogFlashLiquidationSuccess");
        });
        it("should emit LogProfitOrLoss after flashLendingCall finishes", async function () {
            const abiEncoder = new ethers.AbiCoder;
            const callData = abiEncoder.encode(
                ["address", "address", "address", "address", "uint256"],
                [otherAccount.address, mockTokenAdapter.target, mockUniswapV2Router.target, ethers.ZeroAddress, 10000]
            );
            await mockERC20FXD.mint(liquidationStrategy.target, ethers.parseEther("1000000"));
            await expect(liquidationStrategy.connect(owner).flashLendingCall(
                owner.address, ethers.parseEther("1000"), ethers.parseEther("500"), callData
            ))
            .to.emit(liquidationStrategy, "LogProfitOrLoss");
        });
    });
});

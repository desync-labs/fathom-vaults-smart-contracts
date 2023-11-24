const {
    time,
    loadFixture,
  } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { userDeposit, checkVaultEmpty, initialSetup, createProfit } = require("./utils/helper");

describe("Vault Contract", function () {   
    
    // We define a fixture to reuse the same setup in every test.
    // We use loadFixture to run this setup once, snapshot that state,
    // and reset Hardhat Network to that snapshot in every test.
    async function deployVault() {
        const vaultName = 'FathomVault';
        const vaultSymbol = 'FTHVT';
        const vaultDecimals = 18;
        const [owner, otherAccount] = await ethers.getSigners();

        const Asset = await ethers.getContractFactory("Token");
        const asset = await Asset.deploy(vaultSymbol, vaultDecimals, { gasLimit: "0x1000000" });

        const assetAddress = asset.target;
        const profitMaxUnlockTime = 31536000; // 1 year in seconds

        const StrategyManager = await ethers.getContractFactory("StrategyManager");
        const strategyManager = await StrategyManager.deploy(assetAddress, { gasLimit: "0x1000000" });
        // const strategyManager = await ethers.getContractAt("StrategyManager", "0xEAf81a05C7bf87ba57A5265ff5aF6F37958118Da");

        const Vault = await ethers.getContractFactory("FathomVault");
        const vault = await Vault.deploy(assetAddress, vaultName, vaultSymbol, vaultDecimals, profitMaxUnlockTime, strategyManager.target, { gasLimit: "0x1000000" });
        // const vault = await ethers.getContractAt("FathomVault", "0x9989D6191dcc00382AA719B8F0Cc800464f300f1");

        return { vault, owner, otherAccount, asset, strategyManager };
    }

    it("should revert deposit with invalid recipient", async function () {
        const { vault, otherAccount } = await loadFixture(deployVault);
        const amount = 1000;

        await expect(vault.connect(otherAccount).deposit(amount, vault.target)).to.be.revertedWithCustomError(vault, "ExceedDepositLimit");
        await expect(vault.connect(otherAccount).deposit(amount, ethers.ZeroAddress)).to.be.revertedWithCustomError(vault, "ExceedDepositLimit");
    });

    it("should revert deposit with zero funds", async function () {
        const { vault, otherAccount } = await loadFixture(deployVault);
        const amount = 0;

        await expect(vault.connect(otherAccount).deposit(amount, otherAccount.address)).to.be.revertedWithCustomError(vault, "ZeroValue");
    });

    it("should deposit balance within deposit limit", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);
        await asset.approve(vault.target, amount);
    
        await vault.connect(owner).setDepositLimit(amount);
    
        await expect(vault.connect(owner).deposit(amount, owner.address))
            .to.emit(vault, 'Deposit')
            .withArgs(owner.address, owner.address, amount, amount);
    
        // Check the state after deposit
        expect(await vault.totalIdleAmount()).to.equal(amount);
        expect(await vault.balanceOf(owner.address)).to.equal(amount);
        expect(await vault.totalSupplyAmount()).to.equal(amount);
        // Assuming asset is the ERC20 token contract
        expect(await asset.balanceOf(owner.address)).to.equal(0);
    });

    it("should revert when deposit exceeds deposit limit", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);
        await asset.approve(vault.target, amount);

        await vault.setDepositLimit(amount - 1);
    
        await expect(vault.connect(owner).deposit(amount, owner.address))
            .to.be.revertedWithCustomError(vault, "ExceedDepositLimit");
    });

    it("should revert when deposit all exceeds deposit limit", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        const depositLimit = amount / 2;
    
        await vault.setDepositLimit(depositLimit);
        await asset.approve(vault.target, amount);
    
        await expect(vault.connect(owner).deposit(ethers.MaxUint256, owner.address))
            .to.be.revertedWithCustomError(vault, "ExceedDepositLimit");
    });
    
    it("should deposit to delegate", async function () {
        const { vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);
        await asset.approve(vault.target, amount);

        await vault.setDepositLimit(amount);
    
        await expect(vault.connect(owner).deposit(amount, otherAccount))
            .to.emit(vault, 'Deposit')
            .withArgs(owner.address, otherAccount.address, amount, amount);
    
        // owner has no more assets
        expect(await asset.balanceOf(owner.address)).to.equal(0);
        // owner has no shares
        expect(await vault.balanceOf(owner.address)).to.equal(0);
        // otherAccount has been issued vault shares
        expect(await vault.balanceOf(otherAccount.address)).to.equal(amount);
    });

    it("should revert mint with invalid recipient", async function () {
        const { vault, owner } = await loadFixture(deployVault);
        const shares = 100;
    
        await expect(vault.connect(owner).mint(shares, vault.target))
            .to.be.revertedWithCustomError(vault, "ExceedDepositLimit");
        await expect(vault.connect(owner).mint(shares, ethers.ZeroAddress))
            .to.be.revertedWithCustomError(vault, "ExceedDepositLimit");
    });
    
    it("should revert mint with zero funds", async function () {
        const { vault, owner } = await loadFixture(deployVault);
        const shares = 0;
    
        await expect(vault.connect(owner).mint(shares, owner.address))
            .to.be.revertedWithCustomError(vault, "ZeroValue");
    });

    it("should mint within deposit limit", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);    
        await asset.approve(vault.target, amount);
        await vault.setDepositLimit(amount);
    
        await expect(vault.connect(owner).mint(amount, owner.address))
            .to.emit(vault, 'Deposit')
            .withArgs(owner.address, owner.address, amount, amount);
    
        expect(await vault.totalIdleAmount()).to.equal(amount);
        expect(await vault.balanceOf(owner.address)).to.equal(amount);
        expect(await vault.totalSupplyAmount()).to.equal(amount);
        expect(await asset.balanceOf(owner.address)).to.equal(0);
    });
    
    it("should revert mint when exceeding deposit limit", async function () {
        const { vault, owner } = await loadFixture(deployVault);
        const amount = 1000;

        await vault.setDepositLimit(amount - 1);
    
        await expect(vault.connect(owner).mint(amount, owner.address))
            .to.be.revertedWithCustomError(vault, "ExceedDepositLimit");
    });
    
    it("should mint to delegate", async function () {
        const { vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);    
        await asset.approve(vault.target, amount);
        await vault.setDepositLimit(amount);
    
        await asset.approve(vault.target, amount);
    
        await expect(vault.connect(owner).mint(amount, otherAccount.address))
            .to.emit(vault, 'Deposit')
            .withArgs(owner.address, otherAccount.address, amount, amount);

        // owner has no more assets
        expect(await asset.balanceOf(owner.address)).to.equal(0);
        // owner has no shares
        expect(await vault.balanceOf(owner.address)).to.equal(0);
        // otherAccount has been issued vault shares
        expect(await vault.balanceOf(otherAccount.address)).to.equal(amount);
    });
    
    it("should withdraw successfully", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vault.setDepositLimit(amount);

        await userDeposit(owner, vault, asset, amount);
    
        await expect(vault.connect(owner).withdraw(amount, owner.address, owner.address, 0, []))
            .to.emit(vault, 'Withdraw')
            .withArgs(owner.address, owner.address, owner.address, amount, amount);
    
        // Check if vault is empty and owner has received the assets
        expect(await vault.totalIdleAmount()).to.equal(0);
        expect(await asset.balanceOf(vault.target)).to.equal(0);
        expect(await asset.balanceOf(owner.address)).to.equal(amount);
    });

    it("should revert on withdraw with insufficient shares", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        const shares = amount + 1;
        await vault.setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount);
    
        await expect(vault.connect(owner).withdraw(shares, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vault, "InsufficientShares");
    });

    it("should revert on withdraw with no shares", async function () {
        const { vault, owner } = await loadFixture(deployVault);
        const shares = 0;
    
        await expect(vault.connect(owner).withdraw(shares, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vault, "ZeroValue");
    });
    
    it("should withdraw to delegate", async function () {
        const { vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vault.setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount);
    
        await expect(vault.connect(owner).withdraw(amount, otherAccount.address, owner.address, 0, []))
            .to.emit(vault, 'Withdraw')
            .withArgs(owner.address, otherAccount.address, owner.address, amount, amount);
    
        // owner no longer has shares
        expect(await vault.balanceOf(owner.address)).to.equal(0);
        // owner did not receive tokens
        expect(await asset.balanceOf(owner.address)).to.equal(0);
        // otherAccount has tokens
        expect(await asset.balanceOf(otherAccount.address)).to.equal(amount);
    });
    
    it("should withdraw with delegation and sufficient allowance", async function () {
        const { vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vault.setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount);
    
        await vault.connect(owner).approve(otherAccount.address, amount);
    
        await expect(vault.connect(otherAccount).withdraw(amount, owner.address, owner.address, 0, []))
            .to.emit(vault, 'Withdraw')
            .withArgs(otherAccount.address, owner.address, owner.address, amount, amount);
    
        await checkVaultEmpty(vault);
        expect(await vault.allowance(owner.address, otherAccount.address)).to.equal(0);
        expect(await asset.balanceOf(vault.target)).to.equal(0);
        expect(await asset.balanceOf(owner.address)).to.equal(amount);
    });

    it("should revert on withdraw with delegation and insufficient allowance", async function () {
        const { vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vault.setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount);
    
        await expect(vault.connect(otherAccount).withdraw(amount, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vault, "ERC20InsufficientAllowance");
    });
    
    it("should redeem successfully", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vault.setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount);
    
        await expect(vault.connect(owner).redeem(amount, owner.address, owner.address, 0, []))
            .to.emit(vault, 'Withdraw')
            .withArgs(owner.address, owner.address, owner.address, amount, amount);
    
        await checkVaultEmpty(vault);
        expect(await asset.balanceOf(vault.target)).to.equal(0);
        expect(await asset.balanceOf(owner.address)).to.equal(amount);
    });

    it("should revert on redeem with insufficient shares", async function () {
        const { vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vault.setDepositLimit(amount);
        const redemptionAmount = amount + 1;
    
        await userDeposit(owner, vault, asset, amount);
    
        await expect(vault.connect(owner).redeem(redemptionAmount, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vault, "InsufficientShares");
    });
    
    it("should revert on redeem with no shares", async function () {
        const { vault, owner } = await loadFixture(deployVault);
        const amount = 0;
    
        await expect(vault.connect(owner).redeem(amount, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vault, "ZeroValue");
    });

    it("should redeem to delegate", async function () {
        const { vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vault.setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount);
    
        await expect(vault.connect(owner).redeem(amount, otherAccount.address, owner.address, 0, []))
            .to.emit(vault, 'Withdraw')
            .withArgs(owner.address, otherAccount.address, owner.address, amount, amount);
    
        // owner no longer has shares
        expect(await vault.balanceOf(owner.address)).to.equal(0);
        // owner did not receive tokens
        expect(await asset.balanceOf(owner.address)).to.equal(0);
        // otherAccount has tokens
        expect(await asset.balanceOf(otherAccount.address)).to.equal(amount);
    });

    it("should redeem with delegation and sufficient allowance", async function () {
        const { vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vault.setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount);
        await vault.connect(owner).approve(otherAccount.address, amount);
    
        // withdraw as otherAccount to owner
        vault.connect(owner).approve(otherAccount.address, amount);
        await expect(vault.connect(otherAccount).redeem(amount, owner.address, owner.address, 0, []))
            .to.emit(vault, 'Withdraw')
            .withArgs(otherAccount.address, owner.address, owner.address, amount, amount);
    
        await checkVaultEmpty(vault);
        expect(await vault.allowance(owner.address, otherAccount.address)).to.equal(0);
        expect(await asset.balanceOf(vault.target)).to.equal(0);
        expect(await asset.balanceOf(owner.address)).to.equal(amount);
    });
    
    it("should revert on redeem with delegation and insufficient allowance", async function () {
        const { vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vault.setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount);
    
        await expect(vault.connect(otherAccount).redeem(amount, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vault, "ERC20InsufficientAllowance");
    });
    
    it("should set deposit limit correctly", async function () {
        const { vault, owner, otherAccount } = await loadFixture(deployVault);
        const depositLimit = 1000;
    
        const DEPOSIT_LIMIT_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("DEPOSIT_LIMIT_MANAGER"));
        await vault.connect(owner).grantRole(DEPOSIT_LIMIT_MANAGER_ROLE, otherAccount.address);
        await expect(vault.connect(otherAccount).setDepositLimit(depositLimit))
            .to.emit(vault, 'UpdateDepositLimit')
            .withArgs(depositLimit);
    
        expect(await vault.depositLimit()).to.equal(depositLimit);
    });

    // Not working due to delegate call issues with hardhat
    // Needs attention
    it("should mint shares with zero total supply and positive assets", async function () {
        const { vault, owner, asset, strategyManager } = await loadFixture(deployVault); // Replace initialSetUp with your setup function
        const amount = 1000;
        await vault.setDepositLimit(amount);
        const debt = amount / 10;
        const firstProfit = amount / 10;
        const elapsedTime = 14 * 24 * 3600;

        // Simulate time passing
        await time.increase(elapsedTime);
    
        const strategy = await initialSetup(asset, vault, owner, debt, amount, strategyManager);
        await createProfit(asset, strategy, owner, vault, firstProfit);
        await vault.connect(owner).updateDebt(strategy.target, 0);
    
        // there are more shares than deposits (due to profit unlock)
        expect(await vault.totalSupply()).to.be.gt(amount);
    
        // User redeems shares
        await vault.connect(owner).redeem(await vault.balanceOf(owner.address), owner.address, owner.address);
    
        expect(await vault.totalSupply()).to.be.gt(0);
    
        // Simulate time passing
        await time.increase(14 * 24 * 3600);
    
        expect(await vault.totalSupply()).to.equal(0);
    
        await vault.connect(owner).deposit(amount, owner.address);
    
        // shares should be minted at 1:1
        expect(await vault.balanceOf(owner.address)).to.equal(amount);
        expect(await vault.pricePerShare()).to.be.gt(ethers.parseUnits("10", await vault.decimals()));
    });
    
    

});

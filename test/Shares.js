const {
    time,
    loadFixture,
  } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { userDeposit, checkVaultEmpty, initialSetup, createProfit } = require("./utils/helper");
const { hexlify } = require("ethers");

describe("Vault Contract", function () {   
    
    // We define a fixture to reuse the same setup in every test.
    // We use loadFixture to run this setup once, snapshot that state,
    // and reset Hardhat Network to that snapshot in every test.
    async function deployVault() {
        const vaultName = 'Vault Shares FXD';
        const vaultSymbol = 'vFXD';
        const [owner, otherAccount] = await ethers.getSigners();

        const Asset = await ethers.getContractFactory("Token");
        const assetSymbol = 'FXD';
        const vaultDecimals = 18;
        const asset = await Asset.deploy(assetSymbol, vaultDecimals, { gasLimit: "0x1000000" });

        const assetAddress = asset.target;
        const profitMaxUnlockTime = 31536000; // 1 year in seconds

        const VaultPackage = await ethers.getContractFactory("VaultPackage");
        const vaultPackage = await VaultPackage.deploy({ gasLimit: "0x1000000" });
        const Vault = await ethers.getContractFactory("FathomVault");
        const vault = await Vault.deploy(vaultPackage.target, '0x', { gasLimit: "0x1000000" });
        
        const initializeTx = await vaultPackage.attach(vault.target).connect(owner).initialize(
            profitMaxUnlockTime,
            assetAddress,
            vaultName,
            vaultSymbol,
            "0x0000000000000000000000000000000000000000",
            { gasLimit: "0x1000000" }
        );
        await initializeTx.wait();

        return { vaultPackage, vault, owner, otherAccount, asset };
    }

    it("should revert deposit with invalid recipient", async function () {
        const { vaultPackage, vault, otherAccount } = await loadFixture(deployVault);
        const amount = 1000;

        await expect(vaultPackage.attach(vault.target).connect(otherAccount).deposit(amount, vault.target)).to.be.revertedWithCustomError(vaultPackage, "ExceedDepositLimit");
        await expect(vaultPackage.attach(vault.target).connect(otherAccount).deposit(amount, ethers.ZeroAddress)).to.be.revertedWithCustomError(vaultPackage, "ExceedDepositLimit");
    });

    it("should revert deposit with zero funds", async function () {
        const { vaultPackage, vault, otherAccount } = await loadFixture(deployVault);
        const amount = 0;

        await expect(vaultPackage.attach(vault.target).connect(otherAccount).deposit(amount, otherAccount.address)).to.be.revertedWithCustomError(vaultPackage, "ZeroValue");
    });

    it("should deposit balance within deposit limit", async function () {
        const { vaultPackage, vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);
        await asset.approve(vault.target, amount);
    
        await vaultPackage.attach(vault.target).connect(owner).setDepositLimit(amount);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).deposit(amount, owner.address))
            .to.emit(vaultPackage.attach(vault.target), 'Deposit')
            .withArgs(owner.address, owner.address, amount, amount);
    
        // Check the state after deposit
        expect(await vaultPackage.attach(vault.target).totalIdle()).to.equal(amount);
        expect(await vaultPackage.attach(vault.target).balanceOf(owner.address)).to.equal(amount);
        expect(await vaultPackage.attach(vault.target).totalSupplyAmount()).to.equal(amount);
        // Assuming asset is the ERC20 token contract
        expect(await asset.balanceOf(owner.address)).to.equal(0);
    });

    it("should revert when deposit exceeds deposit limit", async function () {
        const { vaultPackage, vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);
        await asset.approve(vault.target, amount);

        await vaultPackage.attach(vault.target).setDepositLimit(amount - 1);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).deposit(amount, owner.address))
            .to.be.revertedWithCustomError(vaultPackage, "ExceedDepositLimit");
    });

    it("should revert when deposit all exceeds deposit limit", async function () {
        const { vaultPackage, vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        const depositLimit = amount / 2;
    
        await vaultPackage.attach(vault.target).setDepositLimit(depositLimit);
        await asset.approve(vault.target, amount);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).deposit(ethers.MaxUint256, owner.address))
            .to.be.revertedWithCustomError(vaultPackage, "ExceedDepositLimit");
    });
    
    it("should deposit to delegate", async function () {
        const { vaultPackage, vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);
        await asset.approve(vault.target, amount);

        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).deposit(amount, otherAccount))
            .to.emit(vaultPackage.attach(vault.target), 'Deposit')
            .withArgs(owner.address, otherAccount.address, amount, amount);
    
        // owner has no more assets
        expect(await asset.balanceOf(owner.address)).to.equal(0);
        // owner has no shares
        expect(await vaultPackage.attach(vault.target).balanceOf(owner.address)).to.equal(0);
        // otherAccount has been issued vault shares
        expect(await vaultPackage.attach(vault.target).balanceOf(otherAccount.address)).to.equal(amount);
    });

    it("should revert mint with invalid recipient", async function () {
        const { vaultPackage, vault, owner } = await loadFixture(deployVault);
        const shares = 100;
    
        await expect(vaultPackage.attach(vault.target).connect(owner).mint(shares, vault.target))
            .to.be.revertedWithCustomError(vaultPackage, "ExceedDepositLimit");
        await expect(vaultPackage.attach(vault.target).connect(owner).mint(shares, ethers.ZeroAddress))
            .to.be.revertedWithCustomError(vaultPackage, "ExceedDepositLimit");
    });
    
    it("should revert mint with zero funds", async function () {
        const { vaultPackage, vault, owner } = await loadFixture(deployVault);
        const shares = 0;
    
        await expect(vaultPackage.attach(vault.target).connect(owner).mint(shares, owner.address))
            .to.be.revertedWithCustomError(vaultPackage, "ZeroValue");
    });

    it("should mint within deposit limit", async function () {
        const { vaultPackage, vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);    
        await asset.approve(vault.target, amount);
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).mint(amount, owner.address))
            .to.emit(vaultPackage.attach(vault.target), 'Deposit')
            .withArgs(owner.address, owner.address, amount, amount);
    
        expect(await vaultPackage.attach(vault.target).totalIdle()).to.equal(amount);
        expect(await vaultPackage.attach(vault.target).balanceOf(owner.address)).to.equal(amount);
        expect(await vaultPackage.attach(vault.target).totalSupplyAmount()).to.equal(amount);
        expect(await asset.balanceOf(owner.address)).to.equal(0);
    });
    
    it("should revert mint when exceeding deposit limit", async function () {
        const { vaultPackage, vault, owner } = await loadFixture(deployVault);
        const amount = 1000;

        await vaultPackage.attach(vault.target).setDepositLimit(amount - 1);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).mint(amount, owner.address))
            .to.be.revertedWithCustomError(vaultPackage, "ExceedDepositLimit");
    });
    
    it("should mint to delegate", async function () {
        const { vaultPackage, vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);    
        await asset.approve(vault.target, amount);
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).mint(amount, otherAccount.address))
            .to.emit(vaultPackage.attach(vault.target), 'Deposit')
            .withArgs(owner.address, otherAccount.address, amount, amount);

        // owner has no more assets
        expect(await asset.balanceOf(owner.address)).to.equal(0);
        // owner has no shares
        expect(await vaultPackage.attach(vault.target).balanceOf(owner.address)).to.equal(0);
        // otherAccount has been issued vault shares
        expect(await vaultPackage.attach(vault.target).balanceOf(otherAccount.address)).to.equal(amount);
    });
    
    it("should withdraw successfully", async function () {
        const { vaultPackage, vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);

        await userDeposit(owner, vault, asset, amount, vaultPackage, vault);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).withdraw(amount, owner.address, owner.address, 0, []))
            .to.emit(vaultPackage.attach(vault.target), 'Withdraw')
            .withArgs(owner.address, owner.address, owner.address, amount, amount);
    
        // Check if vault is empty and owner has received the assets
        expect(await vaultPackage.attach(vault.target).totalIdle()).to.equal(0);
        expect(await asset.balanceOf(vault.target)).to.equal(0);
        expect(await asset.balanceOf(owner.address)).to.equal(amount);
    });

    it("should revert on withdraw with insufficient shares", async function () {
        const { vaultPackage, vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        const shares = amount + 1;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, vaultPackage, vault);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).withdraw(shares, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vaultPackage, "InsufficientShares");
    });

    it("should revert on withdraw with no shares", async function () {
        const { vaultPackage, vault, owner } = await loadFixture(deployVault);
        const shares = 0;
    
        await expect(vaultPackage.attach(vault.target).connect(owner).withdraw(shares, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vaultPackage, "ZeroValue");
    });
    
    it("should withdraw to delegate", async function () {
        const { vaultPackage, vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, vaultPackage, vault);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).withdraw(amount, otherAccount.address, owner.address, 0, []))
            .to.emit(vaultPackage.attach(vault.target), 'Withdraw')
            .withArgs(owner.address, otherAccount.address, owner.address, amount, amount);
    
        // owner no longer has shares
        expect(await vaultPackage.attach(vault.target).balanceOf(owner.address)).to.equal(0);
        // owner did not receive tokens
        expect(await asset.balanceOf(owner.address)).to.equal(0);
        // otherAccount has tokens
        expect(await asset.balanceOf(otherAccount.address)).to.equal(amount);
    });
    
    it("should withdraw with delegation and sufficient allowance", async function () {
        const { vaultPackage, vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, vaultPackage, vault);
    
        await vaultPackage.attach(vault.target).connect(owner).approve(otherAccount.address, amount);
    
        await expect(vaultPackage.attach(vault.target).connect(otherAccount).withdraw(amount, owner.address, owner.address, 0, []))
            .to.emit(vaultPackage.attach(vault.target), 'Withdraw')
            .withArgs(otherAccount.address, owner.address, owner.address, amount, amount);
    
        await checkVaultEmpty(vaultPackage, vault);
        expect(await vaultPackage.attach(vault.target).allowance(owner.address, otherAccount.address)).to.equal(0);
        expect(await asset.balanceOf(vault.target)).to.equal(0);
        expect(await asset.balanceOf(owner.address)).to.equal(amount);
    });

    it("should revert on withdraw with delegation and insufficient allowance", async function () {
        const { vaultPackage, vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, vaultPackage, vault);
    
        await expect(vaultPackage.attach(vault.target).connect(otherAccount).withdraw(amount, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vaultPackage, "ERC20InsufficientAllowance");
    });
    
    it("should redeem successfully", async function () {
        const { vaultPackage, vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, vaultPackage, vault);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).redeem(amount, owner.address, owner.address, 0, []))
            .to.emit(vaultPackage.attach(vault.target), 'Withdraw')
            .withArgs(owner.address, owner.address, owner.address, amount, amount);
    
        await checkVaultEmpty(vaultPackage, vault);
        expect(await asset.balanceOf(vault.target)).to.equal(0);
        expect(await asset.balanceOf(owner.address)).to.equal(amount);
    });

    it("should revert on redeem with insufficient shares", async function () {
        const { vaultPackage, vault, owner, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
        const redemptionAmount = amount + 1;
    
        await userDeposit(owner, vault, asset, amount, vaultPackage, vault);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).redeem(redemptionAmount, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vaultPackage, "InsufficientShares");
    });
    
    it("should revert on redeem with no shares", async function () {
        const { vaultPackage, vault, owner } = await loadFixture(deployVault);
        const amount = 0;
    
        await expect(vaultPackage.attach(vault.target).connect(owner).redeem(amount, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vaultPackage, "ZeroValue");
    });

    it("should redeem to delegate", async function () {
        const { vaultPackage, vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, vaultPackage, vault);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).redeem(amount, otherAccount.address, owner.address, 0, []))
            .to.emit(vaultPackage.attach(vault.target), 'Withdraw')
            .withArgs(owner.address, otherAccount.address, owner.address, amount, amount);
    
        // owner no longer has shares
        expect(await vaultPackage.attach(vault.target).balanceOf(owner.address)).to.equal(0);
        // owner did not receive tokens
        expect(await asset.balanceOf(owner.address)).to.equal(0);
        // otherAccount has tokens
        expect(await asset.balanceOf(otherAccount.address)).to.equal(amount);
    });

    it("should redeem with delegation and sufficient allowance", async function () {
        const { vaultPackage, vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, vaultPackage, vault);
        await vaultPackage.attach(vault.target).connect(owner).approve(otherAccount.address, amount);
    
        // withdraw as otherAccount to owner
        vaultPackage.attach(vault.target).connect(owner).approve(otherAccount.address, amount);
        await expect(vaultPackage.attach(vault.target).connect(otherAccount).redeem(amount, owner.address, owner.address, 0, []))
            .to.emit(vaultPackage.attach(vault.target), 'Withdraw')
            .withArgs(otherAccount.address, owner.address, owner.address, amount, amount);
    
        await checkVaultEmpty(vaultPackage, vault);
        expect(await vaultPackage.attach(vault.target).allowance(owner.address, otherAccount.address)).to.equal(0);
        expect(await asset.balanceOf(vault.target)).to.equal(0);
        expect(await asset.balanceOf(owner.address)).to.equal(amount);
    });
    
    it("should revert on redeem with delegation and insufficient allowance", async function () {
        const { vaultPackage, vault, owner, otherAccount, asset } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, vaultPackage, vault);
    
        await expect(vaultPackage.attach(vault.target).connect(otherAccount).redeem(amount, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vaultPackage, "ERC20InsufficientAllowance");
    });
    
    it("should set deposit limit correctly", async function () {
        const { vaultPackage, vault, owner, otherAccount } = await loadFixture(deployVault);
        const depositLimit = 1000;
    
        const DEFAULT_ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000";
        await vaultPackage.attach(vault.target).connect(owner).grantRole(DEFAULT_ADMIN_ROLE, otherAccount.address);
        await expect(vaultPackage.attach(vault.target).connect(otherAccount).setDepositLimit(depositLimit))
            .to.emit(vaultPackage.attach(vault.target), 'UpdatedDepositLimit')
            .withArgs(depositLimit);
    
        expect(await vaultPackage.attach(vault.target).depositLimit()).to.equal(depositLimit);
    });

    // Not working due to delegate call issues with hardhat
    // Needs attention
    it("should mint shares with zero total supply and positive assets", async function () {
        const { vaultPackage, vault, owner, asset } = await loadFixture(deployVault); // Replace initialSetUp with your setup function
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
        const maxDebt = amount;
        const debt = amount / 10;
        const firstProfit = amount / 10;
        const elapsedTime = 14 * 24 * 3600;
        const profitMaxUnlockTime = 31536000; // 1 year in seconds

        // Simulate time passing
        await time.increase(elapsedTime);
    
        // Simulate a Strategy creation, deposit and debt update
        const strategy = await initialSetup(asset, vaultPackage, vault, owner, maxDebt, debt, amount, vaultPackage, vault, vaultPackage, vault, profitMaxUnlockTime);
        await createProfit(asset, vaultPackage, vault, strategy, owner, vaultPackage, vault, firstProfit, 0, 0, 0, 0, 0);
        await vaultPackage.attach(vault.target).connect(owner).updateDebt(vault.target, strategy.target, 0);    
        expect(await vaultPackage.attach(vault.target).totalSupply()).to.be.eq(amount);

        // User redeems shares
        await vaultPackage.attach(vault.target).connect(owner).redeem(await vaultPackage.attach(vault.target).balanceOf(owner.address), owner.address, owner.address, 0, []);    
        expect(await vaultPackage.attach(vault.target).totalSupply()).to.be.eq(0);
    
        // Simulate time passing
        await time.increase(14 * 24 * 3600);
    
        await vaultPackage.attach(vault.target).connect(owner).deposit(amount, owner.address);
    
        // shares should be minted at 1:1
        expect(await vaultPackage.attach(vault.target).balanceOf(owner.address)).to.equal(amount);
        expect(await vaultPackage.attach(vault.target).pricePerShare()).to.be.eq(ethers.parseUnits("1", await vaultPackage.attach(vault.target).decimals()));
    });
});

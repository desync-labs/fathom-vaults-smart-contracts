const {
    time,
    loadFixture,
  } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { userDeposit, checkVaultEmpty, initialSetup, createProfit } = require("../../utils/helper");
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
        const assetType = 1; // 1 for Normal / 2 for Deflationary / 3 for Rebasing

        const assetAddress = asset.target;

        const performanceFee = 100; // 1% of gain
        const protocolFee = 2000; // 20% of total fee
        const profitMaxUnlockTime = 31536000; // 1 year in seconds

        const Accountant = await ethers.getContractFactory("GenericAccountant");
        const accountant = await Accountant.deploy(performanceFee, owner.address, owner.address, { gasLimit: "0x1000000" });

        const VaultPackage = await ethers.getContractFactory("VaultPackage");
        const vaultPackage = await VaultPackage.deploy({ gasLimit: "0x1000000" });

        const FactoryPackage = await ethers.getContractFactory("FactoryPackage");
        const factoryPackage = await FactoryPackage.deploy({ gasLimit: "0x1000000" });

        const Factory = await ethers.getContractFactory("Factory");
        const factoryProxy = await Factory.deploy(factoryPackage.target, owner.address, "0x", { gasLimit: "0x1000000" });

        const factory = await ethers.getContractAt("FactoryPackage", factoryProxy.target);
        await factory.initialize(vaultPackage.target, owner.address, protocolFee);

        await factory.addVaultPackage(vaultPackage.target);
        
        await factory.deployVault(
            0,
            profitMaxUnlockTime,
            assetType,
            assetAddress,
            vaultName,
            vaultSymbol,
            accountant.target,
            owner.address
        );
        const vaults = await factory.getVaults();
        console.log("Existing Vaults = ", vaults);
        const vaultsCopy = [...vaults];
        const vaultAddress = vaultsCopy.pop();
        const vault = await ethers.getContractAt("VaultPackage", vaultAddress);
        console.log("The Last Vault Address = ", vaultAddress);

        const STRATEGY_MANAGER = ethers.keccak256(ethers.toUtf8Bytes("STRATEGY_MANAGER"));
        const REPORTING_MANAGER = ethers.keccak256(ethers.toUtf8Bytes("REPORTING_MANAGER"));
        const DEBT_PURCHASER = ethers.keccak256(ethers.toUtf8Bytes("DEBT_PURCHASER"));
    
        await vault.grantRole(STRATEGY_MANAGER, owner.address);
        await vault.grantRole(REPORTING_MANAGER, owner.address);
        await vault.grantRole(DEBT_PURCHASER, owner.address);

        return { vault, owner, otherAccount, asset, factory };
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
        expect(await vault.totalIdle()).to.equal(amount);
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
    
        expect(await vault.totalIdle()).to.equal(amount);
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
        expect(await vault.totalIdle()).to.equal(0);
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
    
        await userDeposit(owner, vault, asset, amount,);
    
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
    
        const DEFAULT_ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000";
        await vault.connect(owner).grantRole(DEFAULT_ADMIN_ROLE, otherAccount.address);
        await expect(vault.connect(otherAccount).setDepositLimit(depositLimit))
            .to.emit(vault, 'UpdatedDepositLimit')
            .withArgs(depositLimit);
    
        expect(await vault.depositLimit()).to.equal(depositLimit);
    });

    // Not working due to delegate call issues with hardhat
    // Needs attention
    it("should mint shares with zero total supply and positive assets", async function () {
        const { vault, owner, asset, factory } = await loadFixture(deployVault); // Replace initialSetUp with your setup function
        const amount = 1000;
        await vault.setDepositLimit(amount);
        const maxDebt = amount;
        const debt = amount / 10;
        const firstProfit = amount / 10;
        const elapsedTime = 14 * 24 * 3600;
        const profitMaxUnlockTime = 31536000; // 1 year in seconds

        // Simulate time passing
        await time.increase(elapsedTime);
    
        // Simulate a Strategy creation, deposit and debt update
        const strategy = await initialSetup(asset, vault, owner, maxDebt, debt, amount, profitMaxUnlockTime, factory.target);
        await createProfit(asset, vault, strategy, owner, firstProfit, 0, 0, 0, 0, 0);
        await vault.connect(owner).updateDebt(strategy.target, 0);    
        expect(await vault.totalSupply()).to.be.eq(amount);

        // User redeems shares
        await vault.connect(owner).redeem(await vault.balanceOf(owner.address), owner.address, owner.address, 0, []);    
        expect(await vault.totalSupply()).to.be.eq(0);
    
        // Simulate time passing
        await time.increase(14 * 24 * 3600);
    
        await vault.connect(owner).deposit(amount, owner.address);
    
        // shares should be minted at 1:1
        expect(await vault.balanceOf(owner.address)).to.equal(amount);
        expect(await vault.pricePerShare()).to.be.eq(ethers.parseUnits("1", await vault.decimals()));
    });
});

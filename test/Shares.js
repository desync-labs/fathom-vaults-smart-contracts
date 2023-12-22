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
        const vaultDecimals = 18;
        const [owner, otherAccount] = await ethers.getSigners();

        const Asset = await ethers.getContractFactory("Token");
        const asset = await Asset.deploy(vaultSymbol, vaultDecimals, { gasLimit: "0x1000000" });

        const assetAddress = asset.target;
        const profitMaxUnlockTime = 31536000; // 1 year in seconds

        
        const SharesManagerPackage = await ethers.getContractFactory("SharesManagerPackage");
        const sharesManagerPackage = await SharesManagerPackage.deploy({ gasLimit: "0x1000000" });
        const SharesManager = await ethers.getContractFactory("SharesManager");
        const sharesManager = await SharesManager.deploy(sharesManagerPackage.target, '0x', { gasLimit: "0x1000000" });

        const StrategyManagerPackage = await ethers.getContractFactory("StrategyManagerPackage");
        const strategyManagerPackage = await StrategyManagerPackage.deploy({ gasLimit: "0x1000000" });
        const StrategyManager = await ethers.getContractFactory("StrategyManager");
        const strategyManager = await StrategyManager.deploy(strategyManagerPackage.target, '0x', { gasLimit: "0x1000000" });

        const SettersPackage = await ethers.getContractFactory("SettersPackage");
        const settersPackage = await SettersPackage.deploy({ gasLimit: "0x1000000" });
        const Setters = await ethers.getContractFactory("Setters");
        const setters = await Setters.deploy(settersPackage.target, '0x', { gasLimit: "0x1000000" });

        const GovernancePackage = await ethers.getContractFactory("GovernancePackage");
        const governancePackage = await GovernancePackage.deploy({ gasLimit: "0x1000000" });
        const Governance = await ethers.getContractFactory("Governance");
        const governance = await Governance.deploy(governancePackage.target, '0x', { gasLimit: "0x1000000" });
        // const strategyManager = await ethers.getContractAt("StrategyManager", "0xEAf81a05C7bf87ba57A5265ff5aF6F37958118Da");

        const VaultPackage = await ethers.getContractFactory("VaultPackage");
        const vaultPackage = await VaultPackage.deploy({ gasLimit: "0x1000000" });
        const Vault = await ethers.getContractFactory("FathomVault");
        const vault = await Vault.deploy(vaultPackage.target, '0x', { gasLimit: "0x1000000" });
        // const vault = await ethers.getContractAt("FathomVault", "0x9989D6191dcc00382AA719B8F0Cc800464f300f1");

        const initializeTx = await sharesManagerPackage.attach(sharesManager.target).connect(owner).initialize(strategyManager.target, setters.target, assetAddress, vaultDecimals, vaultName, vaultSymbol, { gasLimit: "0x1000000" });
        await initializeTx.wait();
        const initializeTx2 = await strategyManagerPackage.attach(strategyManager.target).connect(owner).initialize(assetAddress, sharesManager.target, { gasLimit: "0x1000000" });
        await initializeTx2.wait();
        const initializeTx3 = await settersPackage.attach(setters.target).connect(owner).initialize(sharesManager.target, { gasLimit: "0x1000000" });
        await initializeTx3.wait();
        const initializeTx4 = await governancePackage.attach(governance.target).connect(owner).initialize(sharesManager.target, { gasLimit: "0x1000000" });
        await initializeTx4.wait();
        const initializeTx5 = await vaultPackage.attach(vault.target).connect(owner).initialize(profitMaxUnlockTime, strategyManager.target, sharesManager.target, setters.target, governance.target, { gasLimit: "0x1000000" });
        await initializeTx5.wait();

        return { vaultPackage, vault, owner, otherAccount, asset, sharesManagerPackage, sharesManager, strategyManagerPackage, strategyManager, setters, governance };
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
        const { vaultPackage, vault, owner, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);
        await asset.approve(sharesManager.target, amount);
    
        await vaultPackage.attach(vault.target).connect(owner).setDepositLimit(amount);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).deposit(amount, owner.address))
            .to.emit(sharesManagerPackage.attach(sharesManager.target), 'Deposit')
            .withArgs(owner.address, owner.address, amount, amount);
    
        // Check the state after deposit
        expect(await sharesManagerPackage.attach(sharesManager.target).totalIdleAmount()).to.equal(amount);
        expect(await sharesManagerPackage.attach(sharesManager.target).balanceOf(owner.address)).to.equal(amount);
        expect(await sharesManagerPackage.attach(sharesManager.target).totalSupplyAmount()).to.equal(amount);
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
        const { vaultPackage, vault, owner, otherAccount, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);
        await asset.approve(sharesManager.target, amount);

        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).deposit(amount, otherAccount))
            .to.emit(sharesManagerPackage.attach(sharesManager.target), 'Deposit')
            .withArgs(owner.address, otherAccount.address, amount, amount);
    
        // owner has no more assets
        expect(await asset.balanceOf(owner.address)).to.equal(0);
        // owner has no shares
        expect(await sharesManagerPackage.attach(sharesManager.target).balanceOf(owner.address)).to.equal(0);
        // otherAccount has been issued vault shares
        expect(await sharesManagerPackage.attach(sharesManager.target).balanceOf(otherAccount.address)).to.equal(amount);
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
        const { vaultPackage, vault, owner, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);    
        await asset.approve(sharesManager.target, amount);
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).mint(amount, owner.address))
            .to.emit(sharesManagerPackage.attach(sharesManager.target), 'Deposit')
            .withArgs(owner.address, owner.address, amount, amount);
    
        expect(await sharesManagerPackage.attach(sharesManager.target).totalIdleAmount()).to.equal(amount);
        expect(await sharesManagerPackage.attach(sharesManager.target).balanceOf(owner.address)).to.equal(amount);
        expect(await sharesManagerPackage.attach(sharesManager.target).totalSupplyAmount()).to.equal(amount);
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
        const { vaultPackage, vault, owner, otherAccount, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await asset.mint(owner.address, amount);    
        await asset.approve(sharesManager.target, amount);
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).mint(amount, otherAccount.address))
            .to.emit(sharesManagerPackage.attach(sharesManager.target), 'Deposit')
            .withArgs(owner.address, otherAccount.address, amount, amount);

        // owner has no more assets
        expect(await asset.balanceOf(owner.address)).to.equal(0);
        // owner has no shares
        expect(await sharesManagerPackage.attach(sharesManager.target).balanceOf(owner.address)).to.equal(0);
        // otherAccount has been issued vault shares
        expect(await sharesManagerPackage.attach(sharesManager.target).balanceOf(otherAccount.address)).to.equal(amount);
    });
    
    it("should withdraw successfully", async function () {
        const { vaultPackage, vault, owner, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);

        await userDeposit(owner, vault, asset, amount, sharesManagerPackage, sharesManager);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).withdraw(amount, owner.address, owner.address, 0, []))
            .to.emit(sharesManagerPackage.attach(sharesManager.target), 'Withdraw')
            .withArgs(owner.address, owner.address, owner.address, amount, amount);
    
        // Check if vault is empty and owner has received the assets
        expect(await sharesManagerPackage.attach(sharesManager.target).totalIdleAmount()).to.equal(0);
        expect(await asset.balanceOf(vault.target)).to.equal(0);
        expect(await asset.balanceOf(owner.address)).to.equal(amount);
    });

    it("should revert on withdraw with insufficient shares", async function () {
        const { vaultPackage, vault, owner, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        const shares = amount + 1;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, sharesManagerPackage, sharesManager);
    
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
        const { vaultPackage, vault, owner, otherAccount, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, sharesManagerPackage, sharesManager);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).withdraw(amount, otherAccount.address, owner.address, 0, []))
            .to.emit(sharesManagerPackage.attach(sharesManager.target), 'Withdraw')
            .withArgs(owner.address, otherAccount.address, owner.address, amount, amount);
    
        // owner no longer has shares
        expect(await sharesManagerPackage.attach(sharesManager.target).balanceOf(owner.address)).to.equal(0);
        // owner did not receive tokens
        expect(await asset.balanceOf(owner.address)).to.equal(0);
        // otherAccount has tokens
        expect(await asset.balanceOf(otherAccount.address)).to.equal(amount);
    });
    
    it("should withdraw with delegation and sufficient allowance", async function () {
        const { vaultPackage, vault, owner, otherAccount, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, sharesManagerPackage, sharesManager);
    
        await vaultPackage.attach(vault.target).connect(owner).approve(otherAccount.address, amount);
    
        await expect(vaultPackage.attach(vault.target).connect(otherAccount).withdraw(amount, owner.address, owner.address, 0, []))
            .to.emit(sharesManagerPackage.attach(sharesManager.target), 'Withdraw')
            .withArgs(otherAccount.address, owner.address, owner.address, amount, amount);
    
        await checkVaultEmpty(sharesManagerPackage, sharesManager);
        expect(await sharesManagerPackage.attach(sharesManager.target).allowance(owner.address, otherAccount.address)).to.equal(0);
        expect(await asset.balanceOf(vault.target)).to.equal(0);
        expect(await asset.balanceOf(owner.address)).to.equal(amount);
    });

    it("should revert on withdraw with delegation and insufficient allowance", async function () {
        const { vaultPackage, vault, owner, otherAccount, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, sharesManagerPackage, sharesManager);
    
        await expect(vaultPackage.attach(vault.target).connect(otherAccount).withdraw(amount, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vaultPackage, "ERC20InsufficientAllowance");
    });
    
    it("should redeem successfully", async function () {
        const { vaultPackage, vault, owner, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, sharesManagerPackage, sharesManager);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).redeem(amount, owner.address, owner.address, 0, []))
            .to.emit(sharesManagerPackage.attach(sharesManager.target), 'Withdraw')
            .withArgs(owner.address, owner.address, owner.address, amount, amount);
    
        await checkVaultEmpty(sharesManagerPackage, sharesManager);
        expect(await asset.balanceOf(vault.target)).to.equal(0);
        expect(await asset.balanceOf(owner.address)).to.equal(amount);
    });

    it("should revert on redeem with insufficient shares", async function () {
        const { vaultPackage, vault, owner, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
        const redemptionAmount = amount + 1;
    
        await userDeposit(owner, vault, asset, amount, sharesManagerPackage, sharesManager);
    
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
        const { vaultPackage, vault, owner, otherAccount, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, sharesManagerPackage, sharesManager);
    
        await expect(vaultPackage.attach(vault.target).connect(owner).redeem(amount, otherAccount.address, owner.address, 0, []))
            .to.emit(sharesManagerPackage.attach(sharesManager.target), 'Withdraw')
            .withArgs(owner.address, otherAccount.address, owner.address, amount, amount);
    
        // owner no longer has shares
        expect(await sharesManagerPackage.attach(sharesManager.target).balanceOf(owner.address)).to.equal(0);
        // owner did not receive tokens
        expect(await asset.balanceOf(owner.address)).to.equal(0);
        // otherAccount has tokens
        expect(await asset.balanceOf(otherAccount.address)).to.equal(amount);
    });

    it("should redeem with delegation and sufficient allowance", async function () {
        const { vaultPackage, vault, owner, otherAccount, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, sharesManagerPackage, sharesManager);
        await vaultPackage.attach(vault.target).connect(owner).approve(otherAccount.address, amount);
    
        // withdraw as otherAccount to owner
        vaultPackage.attach(vault.target).connect(owner).approve(otherAccount.address, amount);
        await expect(vaultPackage.attach(vault.target).connect(otherAccount).redeem(amount, owner.address, owner.address, 0, []))
            .to.emit(sharesManagerPackage.attach(sharesManager.target), 'Withdraw')
            .withArgs(otherAccount.address, owner.address, owner.address, amount, amount);
    
        await checkVaultEmpty(sharesManagerPackage, sharesManager);
        expect(await sharesManagerPackage.attach(sharesManager.target).allowance(owner.address, otherAccount.address)).to.equal(0);
        expect(await asset.balanceOf(vault.target)).to.equal(0);
        expect(await asset.balanceOf(owner.address)).to.equal(amount);
    });
    
    it("should revert on redeem with delegation and insufficient allowance", async function () {
        const { vaultPackage, vault, owner, otherAccount, asset, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const amount = 1000;
        await vaultPackage.attach(vault.target).setDepositLimit(amount);
    
        await userDeposit(owner, vault, asset, amount, sharesManagerPackage, sharesManager);
    
        await expect(vaultPackage.attach(vault.target).connect(otherAccount).redeem(amount, owner.address, owner.address, 0, []))
            .to.be.revertedWithCustomError(vaultPackage, "ERC20InsufficientAllowance");
    });
    
    it("should set deposit limit correctly", async function () {
        const { vaultPackage, vault, owner, otherAccount, sharesManagerPackage, sharesManager } = await loadFixture(deployVault);
        const depositLimit = 1000;
    
        const DEPOSIT_LIMIT_MANAGER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("DEPOSIT_LIMIT_MANAGER"));
        await vaultPackage.attach(vault.target).connect(owner).grantRole(DEPOSIT_LIMIT_MANAGER_ROLE, otherAccount.address);
        await expect(vaultPackage.attach(vault.target).connect(otherAccount).setDepositLimit(depositLimit))
            .to.emit(sharesManagerPackage.attach(sharesManager.target), 'UpdateDepositLimit')
            .withArgs(depositLimit);
    
        expect(await sharesManagerPackage.attach(sharesManager.target).depositLimit()).to.equal(depositLimit);
    });

    // Not working due to delegate call issues with hardhat
    // Needs attention
    it("should mint shares with zero total supply and positive assets", async function () {
        const { vaultPackage, vault, owner, asset, strategyManagerPackage, strategyManager, sharesManagerPackage, sharesManager } = await loadFixture(deployVault); // Replace initialSetUp with your setup function
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
        const strategy = await initialSetup(asset, vaultPackage, vault, owner, maxDebt, debt, amount, strategyManagerPackage, strategyManager, sharesManagerPackage, sharesManager, profitMaxUnlockTime);
        await createProfit(asset, strategyManagerPackage, strategyManager, strategy, owner, vaultPackage, vault, firstProfit, 0, 0, 0, 0, 0);
        await vaultPackage.attach(vault.target).connect(owner).updateDebt(sharesManager.target, strategy.target, 0);    
        expect(await sharesManagerPackage.attach(sharesManager.target).totalSupply()).to.be.eq(amount);

        // User redeems shares
        await vaultPackage.attach(vault.target).connect(owner).redeem(await sharesManagerPackage.attach(sharesManager.target).balanceOf(owner.address), owner.address, owner.address, 0, []);    
        expect(await sharesManagerPackage.attach(sharesManager.target).totalSupply()).to.be.eq(0);
    
        // Simulate time passing
        await time.increase(14 * 24 * 3600);
    
        await vaultPackage.attach(vault.target).connect(owner).deposit(amount, owner.address);
    
        // shares should be minted at 1:1
        expect(await sharesManagerPackage.attach(sharesManager.target).balanceOf(owner.address)).to.equal(amount);
        expect(await vaultPackage.attach(vault.target).pricePerShare()).to.be.eq(ethers.parseUnits("1", await sharesManager.decimals()));
    });
    
    

});

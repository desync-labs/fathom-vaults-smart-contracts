const { expect } = require("chai");
const { ethers, deployments, getNamedAccounts } = require("hardhat");
const {
    loadFixture,
  } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

/// @dev Storage slot with the address of the current implementation.
/// This is the keccak-256 hash of "eip1967.proxy.implementation" subtracted by 1, from ERC1967Upgrade contract.
const implementationStorageSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

describe("Factory Contract Upgradability", function () {

    async function deployFactory() {
        const [owner, otherAccount] = await ethers.getSigners();

        const FactoryPackage = await ethers.getContractFactory("FactoryPackage");
        const factoryPackage = await FactoryPackage.deploy();

        const FactoryABI = await ethers.getContractFactory("Factory");
        const Factory = await FactoryABI.deploy(factoryPackage.target, owner.address, "0x");
        const factory = await ethers.getContractAt("FactoryPackage", Factory.target);
        
        const VaultPackage = await ethers.getContractFactory("VaultPackage");
        const vaultPackage = await VaultPackage.deploy();

        await factory.initialize(vaultPackage.target, owner.address, 0);

        return { factory, Factory, FactoryPackage, otherAccount, vaultPackage, VaultPackage };
    }

    it("should deploy the contract", async function () {
        const { factory } = await loadFixture(deployFactory);
        expect(factory.target).to.be.properAddress;
    });

    it("should upgrade the contract", async function () {
        const { Factory, FactoryPackage } = await loadFixture(deployFactory);
        // Deploy the upgraded version of the Factory contract
        const newFactory = await FactoryPackage.deploy();
        // Upgrade the Factory contract
        await Factory.setImplementation(newFactory.target, "0x");
        // Verify that the Factory contract was upgraded
        let implementationAddress = await ethers.provider.getStorage(Factory.target, implementationStorageSlot);
        // Remove leading zeros
        implementationAddress = ethers.stripZerosLeft(implementationAddress);
        expect(implementationAddress).to.equal(newFactory.target.toLowerCase());
    });

    it("should not allow non-owner to upgrade the contract", async function () {
        const { Factory, FactoryPackage, otherAccount } = await loadFixture(deployFactory);
        // Deploy the upgraded version of the Factory contract
        const newFactory = await FactoryPackage.deploy();
        // Attempt to upgrade the Factory contract
        const errorMessage = new RegExp(`AccessControl: account ${otherAccount.address.toLowerCase()} is missing role 0x0000000000000000000000000000000000000000000000000000000000000000`);

        await expect(Factory.connect(otherAccount).setImplementation(newFactory.target, "0x"))
            .to.be.revertedWith(errorMessage);
    });

    it("should upgrade the contract and emit an event", async function () {
        const { Factory, FactoryPackage } = await loadFixture(deployFactory);
        // Deploy the upgraded version of the Factory contract
        const newFactory = await FactoryPackage.deploy();
        // Upgrade the Factory contract
        await expect(Factory.setImplementation(newFactory.target, "0x"))
            .to.emit(Factory, "Upgraded")
            .withArgs(newFactory.target);
    });

    describe("addVaultPackageAndUpdateTo()", function () {
        it("should update vault implementation address", async function () {
            const { factory, VaultPackage } = await loadFixture(deployFactory);
            const vaultPackage = await VaultPackage.deploy();
            // Update the vault implementation address
            await factory.addVaultPackageAndUpdateTo(vaultPackage.target);
            // Verify that the vault implementation address was updated
            let vaultPackageAddress = await factory.vaultPackage();
            expect(vaultPackageAddress).to.equal(vaultPackage.target);
        });
    
        it("should not allow non-owner to update vault implementation address", async function () {
            const { factory, FactoryPackage, vaultPackage, otherAccount } = await loadFixture(deployFactory);
            // Attempt to update the vault implementation address
            const errorMessage = new RegExp(`AccessControl: account ${otherAccount.address.toLowerCase()} is missing role 0x0000000000000000000000000000000000000000000000000000000000000000`);
            await expect(factory.connect(otherAccount).addVaultPackageAndUpdateTo(vaultPackage.target)).to.be.revertedWith(errorMessage);
        });
    });

    describe("addVaultPackage()", function () {
        it("should add a new vault package successfully", async function () {
            const { factory, VaultPackage, vaultPackage, owner } = await loadFixture(deployFactory);
            const initialId = await factory.nextVaultPackageId();

            const newVaultPackage = await VaultPackage.deploy();
        
            // Add the vault package
            await factory.addVaultPackage(newVaultPackage.target);
        
            const newVaultPackageAddress = await factory.vaultPackages(initialId);
            expect(newVaultPackageAddress).to.equal(newVaultPackage.target);
            const newId = await factory.nextVaultPackageId();
            expect(newId).to.equal(initialId + BigInt(1));
        });
        
        it("should prevent adding a zero address as a vault package", async function () {
            const { factory, owner } = await loadFixture(deployFactory);
        
            await expect(factory.addVaultPackage(ethers.ZeroAddress))
                .to.be.revertedWithCustomError(factory, "ZeroAddress");
        });
        
        it("should prevent non-owner from adding a vault package", async function () {
            const { factory, vaultPackage, otherAccount } = await loadFixture(deployFactory);

            const errorMessage = new RegExp(`AccessControl: account ${otherAccount.address.toLowerCase()} is missing role 0x0000000000000000000000000000000000000000000000000000000000000000`);
        
            await expect(factory.connect(otherAccount).addVaultPackage(vaultPackage.target))
                .to.be.revertedWith(errorMessage);
        });
    });

    describe("updateVaultPackage()", function () {
        it("should update the vault package successfully", async function () {
            const { factory, vaultPackage, VaultPackage, owner } = await loadFixture(deployFactory);
            const newVaultPackage = await VaultPackage.deploy();

            await expect(factory.addVaultPackage(newVaultPackage.target))
                .to.emit(factory, "VaultPackageAdded")
                .withArgs(1, newVaultPackage.target);
        
            // Update to a new vault package
            await expect(factory.updateVaultPackage(1))
                .to.emit(factory, "VaultPackageUpdated")
                .withArgs(1, newVaultPackage.target);
        
            const currentVaultPackage = await factory.vaultPackage();
            expect(currentVaultPackage).to.equal(newVaultPackage.target);
        });
        
        it("should prevent updating with an invalid package ID", async function () {
            const { factory, owner } = await loadFixture(deployFactory);
        
            await expect(factory.updateVaultPackage(999))
                .to.be.revertedWithCustomError(factory, "InvalidVaultPackageId");
        });
        
        it("should prevent updating to the same vault package", async function () {
            const { factory, VaultPackage, vaultPackage, owner } = await loadFixture(deployFactory);
        
            await expect(factory.updateVaultPackage(0))
                .to.be.revertedWithCustomError(factory, "SameVaultPackage");
        });
        
        it("should prevent non-owner from updating the vault package", async function () {
            const { factory, otherAccount } = await loadFixture(deployFactory);

            const errorMessage = new RegExp(`AccessControl: account ${otherAccount.address.toLowerCase()} is missing role 0x0000000000000000000000000000000000000000000000000000000000000000`);
        
            await expect(factory.connect(otherAccount).updateVaultPackage(1))
                .to.be.revertedWith(errorMessage);
        });        
    });
    
});

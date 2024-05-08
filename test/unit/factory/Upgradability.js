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

        return { factory, Factory, FactoryPackage, owner, otherAccount, vaultPackage, VaultPackage };
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

    describe("addVaultPackage()", function () {
        it("should add a new vault package successfully", async function () {
            const { factory, vaultPackage, owner } = await loadFixture(deployFactory);
            await expect(factory.addVaultPackage(vaultPackage.target))
                .to.emit(factory, 'VaultPackageAdded')
                .withArgs(vaultPackage.target, owner.address);

            expect(await factory.isPackage(vaultPackage)).to.be.true;
        });
        
        it("should prevent adding a zero address as a vault package", async function () {
            const { factory } = await loadFixture(deployFactory);
        
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
});

const { expect } = require("chai");
const { ethers, deployments, getNamedAccounts } = require("hardhat");
const {
    loadFixture,
  } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const implementationStorageSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

describe("Factory Contract Upgradability", function () {

    async function deployFactory() {
        const [owner, otherAccount] = await ethers.getSigners();

        const FactoryPackage = await ethers.getContractFactory("FactoryPackage");
        const factoryPackage = await FactoryPackage.deploy({ gasLimit: "0x1000000" });

        const Factory = await ethers.getContractFactory("Factory");
        const factory = await Factory.deploy(factoryPackage.target, owner.address, "0x", { gasLimit: "0x1000000" });

        const VaultPackage = await ethers.getContractFactory("VaultPackage");
        const vaultPackage = await VaultPackage.deploy({ gasLimit: "0x1000000" });

        return { factory, FactoryPackage, otherAccount, vaultPackage };
    }

    it("should deploy the contract", async function () {
        const { factory } = await loadFixture(deployFactory);
        expect(factory.target).to.be.properAddress;
    });

    it("should upgrade the contract", async function () {
        const { factory, FactoryPackage } = await loadFixture(deployFactory);
        // Deploy the upgraded version of the Factory contract
        const newFactory = await FactoryPackage.deploy({ gasLimit: "0x1000000" });
        // Upgrade the Factory contract
        await factory.setImplementation(newFactory.target, "0x");
        // Verify that the Factory contract was upgraded
        let implementationAddress = await ethers.provider.getStorage(factory.target, implementationStorageSlot);
        // Remove leading zeros
        implementationAddress = ethers.stripZerosLeft(implementationAddress);
        expect(implementationAddress).to.equal(newFactory.target.toLowerCase());
    });

    it("should not allow non-owner to upgrade the contract", async function () {
        const { factory, FactoryPackage, otherAccount } = await loadFixture(deployFactory);
        // Deploy the upgraded version of the Factory contract
        const newFactory = await FactoryPackage.deploy({ gasLimit: "0x1000000" });
        // Attempt to upgrade the Factory contract
        const errorMessage = new RegExp(`AccessControl: account ${otherAccount.address.toLowerCase()} is missing role 0x0000000000000000000000000000000000000000000000000000000000000000`);

        await expect(factory.connect(otherAccount).setImplementation(newFactory.target, "0x"))
            .to.be.revertedWith(errorMessage);
    });

    it("should upgrade the contract and emit an event", async function () {
        const { factory, FactoryPackage } = await loadFixture(deployFactory);
        // Deploy the upgraded version of the Factory contract
        const newFactory = await FactoryPackage.deploy({ gasLimit: "0x1000000" });
        // Upgrade the Factory contract
        await expect(factory.setImplementation(newFactory.target, "0x"))
            .to.emit(factory, "Upgraded")
            .withArgs(newFactory.target);
    });

    it("should update vault implementation address", async function () {
        const { factory, FactoryPackage, vaultPackage } = await loadFixture(deployFactory);
        const factoryContract = await ethers.getContractAt("FactoryPackage", factory.target);
        // Update the vault implementation address
        await factoryContract.updateVaultPackage(vaultPackage.target);
        // Verify that the vault implementation address was updated
        let vaultPackageAddress = await factoryContract.vaultPackage();
        expect(vaultPackageAddress).to.equal(vaultPackage.target);
    });

    it("should not allow non-owner to update vault implementation address", async function () {
        const { factory, FactoryPackage, vaultPackage, otherAccount } = await loadFixture(deployFactory);
        const factoryContract = await ethers.getContractAt("FactoryPackage", factory.target);
        // Attempt to update the vault implementation address
        const errorMessage = new RegExp(`AccessControl: account ${otherAccount.address.toLowerCase()} is missing role 0x0000000000000000000000000000000000000000000000000000000000000000`);
        await expect(factoryContract.connect(otherAccount).updateVaultPackage(vaultPackage.target)).to.be.revertedWith(errorMessage);
    });
});

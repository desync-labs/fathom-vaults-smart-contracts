const { expect } = require("chai");
const { ethers, deployments, getNamedAccounts } = require("hardhat");
const {
    loadFixture,
  } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

/// @dev Storage slot with the address of the current implementation.
/// This is the keccak-256 hash of "eip1967.proxy.implementation" subtracted by 1, from ERC1967Upgrade contract.
const implementationStorageSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

describe("Vault Contract Upgradability", function () {

    async function deployVault() {
        const [owner, otherAccount] = await ethers.getSigners();

        const VaultPackage = await ethers.getContractFactory("VaultPackage");
        const vaultPackage = await VaultPackage.deploy({ gasLimit: "0x1000000" });

        const Vault = await ethers.getContractFactory("FathomVault");
        const vault = await Vault.deploy(vaultPackage.target, "0x", { gasLimit: "0x1000000" });

        return { vault, VaultPackage, otherAccount };
    }

    it("should deploy the contract", async function () {
        const { vault } = await loadFixture(deployVault);
        expect(vault.target).to.be.properAddress;
    });

    it("should upgrade the contract", async function () {
        const { vault, VaultPackage } = await loadFixture(deployVault);
        // Deploy the upgraded version of the Vault contract
        const newVault = await VaultPackage.deploy({ gasLimit: "0x1000000" });
        // Upgrade the Factory contract
        await vault.setImplementation(newVault.target, "0x");
        // Verify that the Factory contract was upgraded
        let implementationAddress = await ethers.provider.getStorage(vault.target, implementationStorageSlot);
        // Remove leading zeros
        implementationAddress = ethers.stripZerosLeft(implementationAddress);
        expect(implementationAddress).to.equal(newVault.target.toLowerCase());
    });

    it("should not allow non-owner to upgrade the contract", async function () {
        const { vault, VaultPackage, otherAccount } = await loadFixture(deployVault);
        // Deploy the upgraded version of the Vault contract
        const newVault = await VaultPackage.deploy({ gasLimit: "0x1000000" });
        // Attempt to upgrade the Vault contract
        const errorMessage = new RegExp(`AccessControl: account ${otherAccount.address.toLowerCase()} is missing role 0x0000000000000000000000000000000000000000000000000000000000000000`);

        await expect(vault.connect(otherAccount).setImplementation(newVault.target, "0x"))
            .to.be.revertedWith(errorMessage);
    });

    it("should upgrade the contract and emit an event", async function () {
        const { vault, VaultPackage } = await loadFixture(deployVault);
        // Deploy the upgraded version of the Vault contract
        const newVault = await VaultPackage.deploy({ gasLimit: "0x1000000" });
        // Upgrade the Vault contract
        await expect(vault.setImplementation(newVault.target, "0x"))
            .to.emit(vault, "Upgraded")
            .withArgs(newVault.target);
    });
});

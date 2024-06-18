const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

const getTheAbi = (contract) => {
    try {
        const dir = path.join(__dirname, "..", "deployments", "apothem", `${contract}.json`);
        const json = JSON.parse(fs.readFileSync(dir, "utf8"));
        return json;
    } catch (e) {
        console.log(`e`, e);
    }
};

module.exports = async ({ getNamedAccounts, deployments }) => {
    // // dev FXD
    // const assetAddress = "0xDf29cB40Cb92a1b8E8337F542E3846E185DefF96"; // Real asset address
    // const factoryAddress = "0xE3E22410ea34661F2b7d5c13EDf7b0c069BD4153"
    
    const uint256max = ethers.MaxUint256;

    // const depositLimit = ethers.parseUnits("50", 18);
    const maxDebt = ethers.parseUnits("1000000", 18); // 1M FXD
    const profitMaxUnlockTime = 0;
    const protocolFee = 2000; // 20% of total fee
    const minimumDeposit = ethers.parseEther("10000"); // 10,000 FXD

    const vaultTokenName = "Trade Fintech Vault Token";
    const vaultTokenSymbol = "fvTFV";

    const { deployer } = await getNamedAccounts();

    const accountantFile = getTheAbi("GenericAccountant");
    const strategyFile = getTheAbi("TradeFintechStrategy");
    const vaultPackageFile = getTheAbi("VaultPackage");
    const kycDepositLimitModuleFile = getTheAbi("KYCDepositLimitModule");

    const asset = await ethers.getContractAt("ERC20", assetAddress);

    const strategyAddress = strategyFile.address;
    const strategy = await ethers.getContractAt("TokenizedStrategy", strategyAddress);

    const accountantAddress = accountantFile.address;
    const vaultPackageAddress = vaultPackageFile.address;

    const kycDepositLimitModuleAddress = kycDepositLimitModuleFile.address;
    const kycDepositLimitModule = await ethers.getContractAt("KYCDepositLimitModule", kycDepositLimitModuleAddress);

    const factory = await ethers.getContractAt("IFactoryOld", factoryAddress);

    console.log("Factory Address = ", factoryAddress);
    console.log("Accountant Address = ", accountantAddress);
    console.log("Strategy Address = ", strategyAddress);
    console.log("Vault Package Address = ", vaultPackageAddress);
    console.log("KYC Deposit Limit Module Address = ", kycDepositLimitModuleAddress);
    console.log("Asset Address = ", assetAddress);

    // return; // Comment this line to continue

    console.log("Updating Vault Package ...");
    // const updateVaultPackageTx = await factory.updateVaultPackage(vaultPackageAddress);
    // await updateVaultPackageTx.wait();

    console.log("Deploying Vault ...");
    const deployVaultTx = await factory.deployVault(
        profitMaxUnlockTime,
        1, // assetType
        assetAddress,
        vaultTokenName,
        vaultTokenSymbol,
        accountantAddress,
        deployer
    );
    await deployVaultTx.wait();

    const vaults = await factory.getVaults();
    console.log("Existing Vaults = ", vaults);
    const vaultsCopy = [...vaults];
    const vaultAddress = vaultsCopy.pop();

    const vault = await ethers.getContractAt("VaultPackage", vaultAddress);
    console.log("The Last Vault Address = ", vaultAddress);
    
    const STRATEGY_MANAGER = ethers.keccak256(ethers.toUtf8Bytes("STRATEGY_MANAGER"));
    const REPORTING_MANAGER = ethers.keccak256(ethers.toUtf8Bytes("REPORTING_MANAGER"));
    const DEBT_PURCHASER = ethers.keccak256(ethers.toUtf8Bytes("DEBT_PURCHASER"));

    await vault.grantRole(STRATEGY_MANAGER, deployer);
    await vault.grantRole(REPORTING_MANAGER, deployer);
    await vault.grantRole(DEBT_PURCHASER, deployer);

    console.log("Roles granted ...");

    // Set new manager
    // await strategy.setPendingManagement(address);
    // await strategy.acceptManagement();

    console.log("Setting profit max unlock time...");
    const setProfitMaxUnlockTx = await strategy.setProfitMaxUnlockTime(0);
    await setProfitMaxUnlockTx.wait();

    console.log("Setting keeper...");
    const setKeeperTx = await strategy.setKeeper(deployer);
    await setKeeperTx.wait();

    console.log("Setting deposit limit...");
    const setDepositLimitTx = await vault.setDepositLimit(uint256max);
    await setDepositLimitTx.wait();

    console.log("Setting deposit limit module...");
    const setDepositLimitModuleTx = await vault.setDepositLimitModule(kycDepositLimitModule.target);
    await setDepositLimitModuleTx.wait();

    console.log("Adding strategy...");
    const addStrategy = await vault.addStrategy(strategy.target);
    await addStrategy.wait();

    console.log("Setting max debt for strategy...");
    const setMaxDebt = await vault.updateMaxDebtForStrategy(strategy.target, maxDebt);
    await setMaxDebt.wait();
    // Set minimum deposit

    console.log("Setting minimum deposit...");
    const setMinDeposit = await vault.setMinUserDeposit(minimumDeposit);
    await setMinDeposit.wait();

    console.log("Approve...");
    const approveTx = await asset.connect(deployer).approve(strategy.target, uint256max);
    await approveTx.wait();
};

module.exports.tags = ["Init"];

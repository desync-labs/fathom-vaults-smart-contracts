
module.exports = async ({ getNamedAccounts, deployments, ethers }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const performanceFee = 1000; // 10% of gain

    const genericAccountant = await deploy("GenericAccountant", {
        from: deployer,
        args: [performanceFee, deployer, deployer],
        log: true,
    });

    const vaultPackage = await deploy("VaultPackage", {
        from: deployer,
        args: [],
        log: true,
    });

    const factoryPackage = await deploy("FactoryPackage", {
        from: deployer,
        args: [],
        log: true,
    });

    const factory = await deploy("Factory", {
        from: deployer,
        args: [factoryPackage.address, deployer, "0x"],
        log: true,
    });

    const strategy = await deploy("TokenizedStrategy", {
        from: deployer,
        args: [factory.address],
        log: true,
    });


    // Set these variables to the appropriate addresses for your deployment
    // below addresses are that of XDC mainnet except for fixedSpreadLiquidationStrategyAddress, which gets deployed newly whenever test set up in XDCForked hardhat node is done.
    const strategyManagerAddress = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; // Replace with actual strategy manager address
    //using account#0 from hardhat node for strategyManagerAddress
    const fixedSpreadLiquidationStrategyAddress = "0x610178dA211FEF7D417bC0e6FeD39F05609AD788"; // Replace with actual fixed spread liquidation strategy address
    //need to get the FSLS address from the terminal log from XDC fork project.
    const wrappedXDCAddress = "0x951857744785e80e2de051c32ee7b25f9c458c42"; // Replace with actual wrapped XDC address
    const bookKeeperAddress = "0x6FD3f049DF9e1886e1DFc1A034D379efaB0603CE"; // Replace with actual bookkeeper address
    const fathomStablecoinAddress = "0x49d3f7543335cf38Fa10889CCFF10207e22110B5"; // Replace with actual Fathom stablecoin address
    const usdTokenAddress = "0xD4B5f10D61916Bd6E0860144a91Ac658dE8a1437"; // Replace with actual USD token address
    const stablecoinAdapterAddress = "0xE3b248A97E9eb778c9B08f20a74c9165E22ef40E"; // Replace with actual stablecoin adapter address


    const liquidationStrategy = await deploy("LiquidationStrategy", {
        from: deployer,
        args: [
            fathomStablecoinAddress, // _asset
            "FXDLiquidationStrategy", // Liquidation Strategy Name
            strategy.address,
            strategyManagerAddress, // _strategyManager
            fixedSpreadLiquidationStrategyAddress, // _fixedSpreadLiquidationStrategy
            wrappedXDCAddress, // _wrappedXDC
            bookKeeperAddress, // _bookKeeper
            usdTokenAddress, // _usdToken
            stablecoinAdapterAddress // _stablecoinAdapter
        ],
        log: true,
        gasLimit: 10000000
    });


    // Vault

    const totalGain = ethers.parseUnits("10", 18);
    // opening position when XDC price is 1 USD
    // const depositAmount = ethers.parseUnits("450", 18);
    // opening position when XDC price is 0.02 USD
    const depositAmount = ethers.parseUnits("90", 18);
    const depositLimit = ethers.parseUnits("500", 18);
    const maxDebt = ethers.parseUnits("500", 18);
    // const profitMaxUnlockTime = 604800; // 7 days seconds
    const profitMaxUnlockTime = 0; // 1 sec

    const protocolFee = 2000; // 20% of total fee

    const vaultTokenName = "FXD-fVault-1";
    const vaultTokenSymbol = "fvFXD1";

    const assetAddress = fathomStablecoinAddress; // Real assetInstance address
    const assetInstance = await ethers.getContractAt("ERC20", assetAddress);

    const liquidationStrategyInstance = await ethers.getContractAt("LiquidationStrategy", liquidationStrategy.address);

    const liqStrategyTokenizedStrategyInstance = await ethers.getContractAt("TokenizedStrategy", liquidationStrategy.address);

    const factoryInstance = await ethers.getContractAt("FactoryPackage", factory.address);

    const factoryInitTx = await factoryInstance.initialize(vaultPackage.address, deployer, protocolFee);
    await factoryInitTx.wait();

    const deployVaultTx = await factoryInstance.deployVault(
        profitMaxUnlockTime,
        assetAddress,
        vaultTokenName,
        vaultTokenSymbol,
        genericAccountant.address,
        deployer
    );

    await deployVaultTx.wait();

    const vaults = await factoryInstance.getVaults();
    console.log("Existing Vaults = ", vaults);
    const vaultsCopy = [...vaults];
    const vaultAddress = vaultsCopy.pop();
    const vault = await ethers.getContractAt("VaultPackage", vaultAddress);
    console.log("The Last Vault Address = ", vaultAddress);

    // Approve tokens for vault
    console.log("Approving tokens for vault...");
    //approve 450 FXD to vault
    const approveTx = await assetInstance.approve(vaultAddress, depositAmount, { gasLimit: "0x1000000" });
    await approveTx.wait(); // Wait for the transaction to be confirmed

    // Set deposit limit
    console.log("Setting deposit limit...");
    const setDepositLimitTx = await vault.setDepositLimit(depositLimit, { gasLimit: "0x1000000" });
    await setDepositLimitTx.wait(); // Wait for the transaction to be confirmed


    // Check balances
    console.log("Updating balances...");
    let balanceInShares = await vault.balanceOf(deployer);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    let balanceInTokens = await vault.convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    let balanceVaultInShares = await vault.balanceOf(vaultAddress);
    console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    let balanceVaultInTokens = await assetInstance.balanceOf(vaultAddress);
    console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    let balanceStrategy = await assetInstance.balanceOf(strategy.address);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    let accountantShares = await vault.balanceOf(genericAccountant.address);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));

    // Simulate a deposit
    console.log("Depositing...");
    const depositTx = await vault.deposit(depositAmount, deployer, { gasLimit: "0x1000000" });
    await depositTx.wait(); // Wait for the transaction to be confirmed

    console.log("Updating balances...");
    balanceInShares = await vault.balanceOf(deployer);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    balanceInTokens = await vault.convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    balanceVaultInShares = await vault.balanceOf(vaultAddress);
    console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    balanceVaultInTokens = await assetInstance.balanceOf(vaultAddress);
    console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    balanceStrategy = await assetInstance.balanceOf(strategy.address);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));


    // Setup Strategy
    console.log("Adding Strategy to the Vault...");
    const addStrategyTx = await vault.addStrategy(liquidationStrategy.address, { gasLimit: "0x1000000" });
    await addStrategyTx.wait();
    console.log("Setting Vault's Strategy maxDebt...");
    const updateMaxDebtForStrategyTx = await vault.updateMaxDebtForStrategy(liquidationStrategy.address, maxDebt, { gasLimit: "0x1000000" });
    await updateMaxDebtForStrategyTx.wait();
    console.log("Update Vault's Strategy debt...");
    const updateDebtTx = await vault.updateDebt(liquidationStrategy.address, balanceVaultInTokens, { gasLimit: "0x1000000" });
    await updateDebtTx.wait();

    console.log("Updating balances...");
    balanceInShares = await vault.balanceOf(deployer);
    console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    balanceInTokens = await vault.convertToAssets(balanceInShares);
    console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    balanceVaultInShares = await vault.balanceOf(vaultAddress);
    console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    balanceVaultInTokens = await assetInstance.balanceOf(vaultAddress);
    console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    balanceStrategy = await assetInstance.balanceOf(liquidationStrategy.address);
    console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    let pricePerShare = await vault.pricePerShare();
    console.log("Price Per Share = ", ethers.formatUnits(pricePerShare, 18));
    let vaultStrategyBalance = await liqStrategyTokenizedStrategyInstance.balanceOf(vaultAddress);
    console.log("Vault Balance on Strategy = ", ethers.formatUnits(vaultStrategyBalance, 18));
    let vaultStrategyBalanceInTokens = await liqStrategyTokenizedStrategyInstance.convertToAssets(vaultStrategyBalance);
    console.log("Vault Balance on Strategy in Tokens = ", ethers.formatUnits(vaultStrategyBalanceInTokens, 18));
    accountantShares = await vault.balanceOf(genericAccountant.address);
    console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));
    let fullProfitUnlockDate = (await vault.fullProfitUnlockDate()).toString();
    console.log("Full Profit Unlock Date = ", fullProfitUnlockDate);


};

module.exports.tags = ["Factory", "GenericAccountant", "VaultPackage", "FactoryPackage", "TokenizedStrategy", "LiquidationStrategy"];

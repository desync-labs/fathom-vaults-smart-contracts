
module.exports = async ({ getNamedAccounts, deployments, ethers }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    // Set these variables to the appropriate addresses for your deployment
    // below addresses are that of XDC mainnet except for fixedSpreadLiquidationStrategyAddress, which gets deployed newly whenever test set up in XDCForked hardhat node is done.
    const strategyManagerAddress = "0x0Eb7DEE6e18Cce8fE839E986502d95d47dC0ADa3"; //2024.03.21 devDeployerAddress
    //using account#0 from hardhat node for strategyManagerAddress
    const fixedSpreadLiquidationStrategyAddress = "0x83Fcf5C671a0BbFA287527410fbD489ef3b23FD4"; //2024.03.21 dev env FSLS address
    //need to get the FSLS address from the terminal log from XDC fork project.
    const wrappedXDCAddress = "0xE99500AB4A413164DA49Af83B9824749059b46ce"; // 2024.03.21 dev env wrappedXDCAddress
    const bookKeeperAddress = "0xe9f8f2B94dFA17e02ce93B9607f9694923Bde153"; // 2024.03.21 dev env bookKeeperAddress
    const fathomStablecoinAddress = "0xDf29cB40Cb92a1b8E8337F542E3846E185DefF96"; // 2024.03.21 dev env fathomStablecoinAddress
    const usdTokenAddress = "0x9dD4761Bd68169478a06156c0C1416fB9506BE78"; // 2024.03.21 dev env usdTokenAddress
    const stablecoinAdapterAddress = "0x2A63856eba3F3A1B07B6Cf3296D5e6f601E26044"; //  2024.03.21 dev env stablecoinAdapterAddress
    const vaultAddress = "0xFEd8e57d02af00cAbBb9418F9C5e1928b4d14f01"; // 2024.03.21 dev env vaultAddress

    const liquidationStrategy = await deploy("LiquidationStrategy", {
        from: deployer,
        args: [
            fathomStablecoinAddress, // _asset
            "FXDLiquidationStrategy", // Liquidation Strategy Name
            "0xD797f2d5952F9bdEd7804a0D348fE75956bF73D8", //2024.03.21 tokenizedStrategyAddress on dev env
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

    console.log(`${liquidationStrategy.address} is the liquidationStrategy address`);


    // Vault

    // const totalGain = ethers.parseUnits("10", 18);
    // opening position when XDC price is 1 USD
    // const depositAmount = ethers.parseUnits("450", 18);
    // opening position when XDC price is 0.02 USD
    const depositAmount = ethers.parseUnits("0000", 18);
    // const depositLimit = ethers.parseUnits("20000", 18);
    const maxDebt = ethers.parseUnits("20000", 18);
    // const profitMaxUnlockTime = 604800; // 7 days seconds
    // const profitMaxUnlockTime = 0; // 1 sec

    // const protocolFee = 2000; // 20% of total fee

    // 2024.03.21 commented out below two lines because Vini already deployed 'em.
    // const vaultTokenName = "FXD-fVault-1";
    // const vaultTokenSymbol = "fvFXD1";

    const assetAddress = fathomStablecoinAddress; // Real assetInstance address
    const assetInstance = await ethers.getContractAt("ERC20", assetAddress);

    // const liquidationStrategyInstance = await ethers.getContractAt("LiquidationStrategy", liquidationStrategy.address);

    const liqStrategyTokenizedStrategyInstance = await ethers.getContractAt("TokenizedStrategy", liquidationStrategy.address);

    // const factoryInstance = await ethers.getContractAt("FactoryPackage", factory.address);

    // const factoryInitTx = await factoryInstance.initialize(vaultPackage.address, deployer, protocolFee);
    // await factoryInitTx.wait();

    // 2024.03.21 commented out below lines because Vini already deployed 'em.
    // const deployVaultTx = await factoryInstance.deployVault(
    //     profitMaxUnlockTime,
    //     assetAddress,
    //     vaultTokenName,
    //     vaultTokenSymbol,
    //     genericAccountant.address,
    //     deployer
    // );

    // await deployVaultTx.wait();

    // const vaults = await factoryInstance.getVaults();
    // console.log("Existing Vaults = ", vaults);
    // const vaultsCopy = [...vaults];
    // const vaultAddress = vaultsCopy.pop();
    const vault = await ethers.getContractAt("VaultPackage", vaultAddress);
    // console.log("The Last Vault Address = ", vaultAddress);

    // Approve tokens for vault
    // console.log("Approving tokens for vault...");
    //approve 450 FXD to vault
    // const approveTx = await assetInstance.approve(vaultAddress, depositAmount, { gasLimit: "0x1000000" });
    // await approveTx.wait(); // Wait for the transaction to be confirmed

    // Set deposit limit
    // console.log("Setting deposit limit...");
    //2024.03.21 depositLimit is 1000000000000000000000000 on dev env
    // const setDepositLimitTx = await vault.setDepositLimit(depositLimit, { gasLimit: "0x1000000" });
    // await setDepositLimitTx.wait(); // Wait for the transaction to be confirmed


    // Check balances
    // console.log("Updating balances...");
    // let balanceInShares = await vault.balanceOf(deployer);
    // console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    // let balanceInTokens = await vault.convertToAssets(balanceInShares);
    // console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    // let balanceVaultInShares = await vault.balanceOf(vaultAddress);
    // console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    // let balanceVaultInTokens = await assetInstance.balanceOf(vaultAddress);
    // console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    // let balanceStrategy = await assetInstance.balanceOf(strategy.address);
    // console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));
    // let accountantShares = await vault.balanceOf(genericAccountant.address);
    // console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));

    // Simulate a deposit
    // console.log("Depositing...");
    // const depositTx = await vault.deposit(depositAmount, deployer, { gasLimit: "0x1000000" });
    // await depositTx.wait(); // Wait for the transaction to be confirmed

    // console.log("Updating balances...");
    // balanceInShares = await vault.balanceOf(deployer);
    // console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    // balanceInTokens = await vault.convertToAssets(balanceInShares);
    // console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    // balanceVaultInShares = await vault.balanceOf(vaultAddress);
    // console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
    // balanceVaultInTokens = await assetInstance.balanceOf(vaultAddress);
    // console.log("Balance of Vault in Tokens = ", ethers.formatUnits(balanceVaultInTokens, 18));
    // balanceStrategy = await assetInstance.balanceOf(strategy.address);
    // console.log("Balance of Strategy = ", ethers.formatUnits(balanceStrategy, 18));


    // Setup Strategy
    // console.log("Adding Strategy to the Vault...");
    // const addStrategyTx = await vault.addStrategy(liquidationStrategy.address, { gasLimit: "0x1000000" });
    // await addStrategyTx.wait();
    // console.log("Setting Vault's Strategy maxDebt...");
    // const updateMaxDebtForStrategyTx = await vault.updateMaxDebtForStrategy(liquidationStrategy.address, maxDebt, { gasLimit: "0x1000000" });
    // await updateMaxDebtForStrategyTx.wait();
    // console.log("Update Vault's Strategy debt...");
    // const updateDebtTx = await vault.updateDebt(liquidationStrategy.address, depositAmount, { gasLimit: "0x1000000" });
    // await updateDebtTx.wait();

    // console.log("Updating balances...");
    // balanceInShares = await vault.balanceOf(deployer);
    // console.log("Balance of Owner in Shares = ", ethers.formatUnits(balanceInShares, 18));
    // balanceInTokens = await vault.convertToAssets(balanceInShares);
    // console.log("Balance of Owner in Tokens = ", ethers.formatUnits(balanceInTokens, 18));
    // balanceVaultInShares = await vault.balanceOf(vaultAddress);
    // console.log("Balance of Vault in Shares = ", ethers.formatUnits(balanceVaultInShares, 18));
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
    // accountantShares = await vault.balanceOf(genericAccountant.address);
    // console.log("Shares of Accountant = ", ethers.formatUnits(accountantShares, 18));
    // let fullProfitUnlockDate = (await vault.fullProfitUnlockDate()).toString();
    // console.log("Full Profit Unlock Date = ", fullProfitUnlockDate);


};

module.exports.tags = ["Factory", "GenericAccountant", "VaultPackage", "FactoryPackage", "TokenizedStrategy", "LiquidationStrategy"];

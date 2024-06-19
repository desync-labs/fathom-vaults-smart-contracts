require("@nomicfoundation/hardhat-toolbox");

// import { task } from 'hardhat/config';

task(`update-pofitMaxUnlockTime`).setAction(async (_, hre) => {
    const factoryAddr = "0xE3E22410ea34661F2b7d5c13EDf7b0c069BD4153";
    const newProfitMaxUnlockTime = 3600; // 1 hour
    
    console.log("Factory Address = ", factoryAddr);
    console.log("Updating Profit Max Unlock Time ...");

    const factory = await ethers.getContractAt("IFactory", factoryAddr);
    const vaults = await factory.getVaults();

    for (let i = 0; i < vaults.length; i++) {
        console.log("Checking Vault = ", vaults[i]);
        const vault = await ethers.getContractAt("VaultPackage", vaults[i]);
        const isShutdown = await vault.shutdown();
        if (isShutdown) {
            console.log("Vault is shutdown");
            continue;
        }
        const currentProfitMaxUnlockTime = await vault.profitMaxUnlockTime();
        console.log("Current Profit Max Unlock Time = ", currentProfitMaxUnlockTime);
        if (currentProfitMaxUnlockTime > 0 && currentProfitMaxUnlockTime != newProfitMaxUnlockTime) {
            console.log("Updating Vault = ", vaults[i]);
            const updateProfitMaxUnlockTimeTx = await vault.setProfitMaxUnlockTime(newProfitMaxUnlockTime);
            await updateProfitMaxUnlockTimeTx.wait();
            console.log("Profit Max Unlock Time Updated = ", vaults[i]);
        } else {
            console.log(`Profit Max Unlock Time is ${currentProfitMaxUnlockTime} -> Skipped`);
        }
        console.log("Update strategies ...");

       const strategies = await vault.getDefaultQueue();
         for (let j = 0; j < strategies.length; j++) {
              console.log("Checking Strategy = ", strategies[j]);
              const strategy = await ethers.getContractAt("TokenizedStrategy", strategies[j]);
              const isShutdown = await strategy.isShutdown();
              if (isShutdown) {
                console.log("Strategy is shutdown = ", strategies[j]);
                continue;
              }
              const currentProfitMaxUnlockTime = await strategy.profitMaxUnlockTime();
              console.log("Current Profit Unlock Time = ", currentProfitMaxUnlockTime);
              if (currentProfitMaxUnlockTime > 0 && currentProfitMaxUnlockTime != newProfitMaxUnlockTime) {
                console.log("Updating Strategy = ", strategies[j]);
                const updateProfitUnlockTimeTx = await strategy.setProfitMaxUnlockTime(newProfitMaxUnlockTime);
                await updateProfitUnlockTimeTx.wait();
                console.log("Profit Unlock Time Updated = ", strategies[j]);
              } else {
                console.log(`Profit Max Unlock Time is ${currentProfitMaxUnlockTime} -> Skipped`);
              }
         }
    }

    // console.log("Existing Vaults = ", vaults);
    // const vaultsCopy = [...vaults];
    // const vaultAddress = vaultsCopy.pop();


});
const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
    time
  } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

async function userDeposit(user, vault, token, amount) {
    await token.mint(user.address, amount);
    const initialBalance = await token.balanceOf(vault.target);
    const allowance = await token.allowance(user.address, vault.target);
    
    if (allowance < amount) {
        const approveTx = await token.connect(user).approve(vault.target, ethers.MaxUint256);
        await approveTx.wait(); // Wait for the transaction to be mined
    }
    
    const depositTx = await vault.connect(user).deposit(amount, user.address);
    await depositTx.wait(); // Wait for the transaction to be mined
    
    const finalBalance = await token.balanceOf(vault.target);
    amount = ethers.toBigInt(amount);
    expect(finalBalance).to.equal(initialBalance + amount);

    return depositTx;
}

async function checkVaultEmpty(vault) {
    expect(await vault.totalAssets()).to.equal(0);
    expect(await vault.totalSupplyAmount()).to.equal(0);
    expect(await vault.totalIdleAmount()).to.equal(0);
    expect(await vault.totalDebtAmount()).to.equal(0);
}

async function createProfit(asset, strategy, owner, vault, profit, totalFees, totalRefunds, byPassFees) {
    // We create a virtual profit
    const initialDebt = await vault.strategies(strategy.address).currentDebt;

    await asset.connect(owner).transfer(strategy.address, profit);
    await strategy.connect(owner).report();
    const tx = await vault.connect(owner).processReport(strategy.address);

    const receipt = await tx.wait();
    const event = receipt.events.find(e => e.event === 'StrategyReported');
    const totalFeesReported = event.args.totalFees;

    return totalFeesReported;
}


async function createStrategy(owner, vault) {
    const Strategy = await ethers.getContractFactory("MockTokenizedStrategy");
    const strategy = await Strategy.deploy(await vault.ASSET(), "Mock Tokenized Strategy", owner.address, owner.address, { gasLimit: "0x1000000" });

    return strategy;
}

async function addStrategyToVault(owner, strategy, vault, strategyManager) {
    const addStrategyTx = await vault.connect(owner).addStrategy(strategy.target);
    const receipt = await addStrategyTx.wait(); // Wait for the transaction to be confirmed
    console.log(receipt);

    const event = receipt.events?.find(
        (e) => e.address === vault.address,
      );
    if (event) {
        const decodedEvent = strategy.interface.decodeEventLog(
            'StrategyChanged',
            event.data,
            event.topics,
        );
        console.log(decodedEvent);
    }

    // await expect(vault.connect(owner).addStrategy(strategy.target))
    //     .to.emit(vault, 'StrategyChanged')
    //     .withArgs(strategy.target, 0);

    // Access the mapping with the strategy's address as the key
    const strategyParams = await vault.strategies(strategy.target);
    console.log(strategyParams);

    console.log("Activation Timestamp:", strategyParams.activation.toString());
    console.log("Last Report Timestamp:", strategyParams.lastReport.toString());
    console.log("Current Debt:", strategyParams.currentDebt.toString());
    console.log("Max Debt:", strategyParams.maxDebt.toString());

    await strategy.connect(owner).setMaxDebt(ethers.MaxUint256);
}

async function addDebtToStrategy(owner, strategy, vault, debt) {
    await vault.connect(owner).updateMaxDebtForStrategy(strategy.target, debt);
    await vault.connect(owner).updateDebt(strategy.target, debt);
}

async function initialSetup(asset, vault, owner, debt, amount, strategyManager) {
    await asset.connect(owner).mint(owner.address, amount);
    const strategy = await createStrategy(owner, vault);
    
    // Deposit assets to vault and get strategy ready
    await userDeposit(owner, vault, asset, amount);
    await addStrategyToVault(owner, strategy, vault, strategyManager);
    await addDebtToStrategy(owner, strategy, vault, debt);

    return strategy;
}

module.exports = { userDeposit, checkVaultEmpty, createProfit, createStrategy, addStrategyToVault, addDebtToStrategy, initialSetup };
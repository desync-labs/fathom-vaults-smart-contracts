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
    expect(await vault.totalIdle()).to.equal(0);
    expect(await vault.totalDebt()).to.equal(0);
}

async function createProfit(asset, vault, strategy, owner, profit, loss, protocolFees, totalFees, totalRefunds, byPassFees) {
    // We create a virtual profit
    // Access the mapping with the strategy's address as the key
    const strategyParams = await vault.strategies(strategy.target);

    const transferTx = await asset.connect(owner).transfer(strategy.target, profit);
    await transferTx.wait();
    const reportTx = await strategy.connect(owner).report();
    await reportTx.wait();

    let totalAssetsOnStrategy = await strategy.connect(owner).balanceOf(vault.target);
    totalAssetsOnStrategy = await strategy.connect(owner).convertToAssets(totalAssetsOnStrategy);

    await expect(vault.connect(owner).processReport(strategy.target))
        .to.emit(vault, 'StrategyReported')
        .withArgs(strategy.target, totalAssetsOnStrategy-strategyParams.currentDebt, loss, strategyParams.currentDebt, protocolFees, totalFees, totalRefunds);

    return totalFees;
}


async function createStrategy(owner, vault, profitMaxUnlockTime) {
    const Strategy = await ethers.getContractFactory("MockTokenizedStrategy");
    const strategy = await Strategy.deploy(await vault.asset(), "Mock Tokenized Strategy", owner.address, owner.address, profitMaxUnlockTime, { gasLimit: "0x1000000" });

    return strategy;
}

async function addStrategyToVault(owner, strategy, vault) {
    await expect(vault.connect(owner).addStrategy(strategy.target))
        .to.emit(vault, 'StrategyChanged')
        .withArgs(strategy.target, 0);

    // Access the mapping with the strategy's address as the key
    const strategyParams = await vault.strategies(strategy.target);

    console.log("Activation Timestamp:", strategyParams.activation.toString());
    console.log("Last Report Timestamp:", strategyParams.lastReport.toString());
    console.log("Current Debt:", strategyParams.currentDebt.toString());
    console.log("Max Debt:", strategyParams.maxDebt.toString());

    await strategy.connect(owner).setMaxDebt(ethers.MaxUint256);

    return strategyParams;
}

async function addDebtToStrategy(owner, strategy, vault, maxDebt, debt, strategyParams, vault) {
    await expect(vault.connect(owner).updateMaxDebtForStrategy(strategy.target, maxDebt))
        .to.emit(vault, 'UpdatedMaxDebtForStrategy')
        .withArgs(owner.address, strategy.target, maxDebt);
    await expect(vault.connect(owner).updateDebt(strategy.target, debt))
        .to.emit(vault, 'DebtUpdated')
        .withArgs(strategy.target, strategyParams.currentDebt, debt);
}

async function initialSetup(asset, vault, owner, maxDebt, debt, amount, profitMaxUnlockTime) {
    await asset.connect(owner).mint(owner.address, amount);
    const strategy = await createStrategy(owner, vault, profitMaxUnlockTime);
    
    // Deposit assets to vault and get strategy ready
    await userDeposit(owner, vault, asset, amount, vault);
    const strategyParams = await addStrategyToVault(owner, strategy, vault);
    await addDebtToStrategy(owner, strategy, vault, maxDebt, debt, strategyParams, vault);

    return strategy;
}

module.exports = { userDeposit, checkVaultEmpty, createProfit, createStrategy, addStrategyToVault, addDebtToStrategy, initialSetup };
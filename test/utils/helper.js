const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
    time
  } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

async function userDeposit(user, vault, token, amount, sharesManagerPackage, sharesManager) {
    await token.mint(user.address, amount);
    const initialBalance = await token.balanceOf(vault.target);
    const allowance = await token.allowance(user.address, vault.target);
    
    if (allowance < amount) {
        const approveTx = await token.connect(user).approve(sharesManager.target, ethers.MaxUint256);
        await approveTx.wait(); // Wait for the transaction to be mined
    }
    
    const depositTx = await sharesManagerPackage.attach(sharesManager.target).connect(user).deposit(amount, user.address);
    await depositTx.wait(); // Wait for the transaction to be mined
    
    const finalBalance = await token.balanceOf(sharesManager.target);
    amount = ethers.toBigInt(amount);
    expect(finalBalance).to.equal(initialBalance + amount);

    return depositTx;
}

async function checkVaultEmpty(vaultPackage, vault) {
    expect(await vaultPackage.attach(vault.target).totalAssets()).to.equal(0);
    expect(await vaultPackage.attach(vault.target).totalSupplyAmount()).to.equal(0);
    expect(await vaultPackage.attach(vault.target).totalIdleAmount()).to.equal(0);
    expect(await vaultPackage.attach(vault.target).totalDebtAmount()).to.equal(0);
}

async function createProfit(asset, strategyManagerPackage, strategyManager, strategy, owner, vaultPackage, vault, profit, loss, protocolFees, totalFees, totalRefunds, byPassFees) {
    // We create a virtual profit
    // Access the mapping with the strategy's address as the key
    const strategyParams = await strategyManagerPackage.attach(strategyManager.target).strategies(strategy.target);

    const transferTx = await asset.connect(owner).transfer(strategy.target, profit);
    await transferTx.wait();
    const reportTx = await strategy.connect(owner).report();
    await reportTx.wait();

    // TODO - Check that the (profit-Number(strategyParams.currentDebt)) is appropriate way to calculate gain
    await expect(vaultPackage.attach(vault.target).connect(owner).processReport(strategy.target))
        .to.emit(strategyManagerPackage.attach(strategyManager.target), 'StrategyReported')
        .withArgs(strategy.target, profit-Number(strategyParams.currentDebt), loss, strategyParams.currentDebt, protocolFees, totalFees, totalRefunds);

    return totalFees;
}


async function createStrategy(owner, sharesManagerPackage, sharesManager, profitMaxUnlockTime) {
    const Strategy = await ethers.getContractFactory("MockTokenizedStrategy");
    const strategy = await Strategy.deploy(await sharesManagerPackage.attach(sharesManager.target).asset(), "Mock Tokenized Strategy", owner.address, owner.address, profitMaxUnlockTime, { gasLimit: "0x1000000" });

    return strategy;
}

async function addStrategyToVault(owner, strategy, vaultPackage, vault, strategyManagerPackage, strategyManager) {
    await expect(vaultPackage.attach(vault.target).connect(owner).addStrategy(strategy.target))
        .to.emit(strategyManagerPackage.attach(strategyManager.target), 'StrategyChanged')
        .withArgs(strategy.target, 0);

    // Access the mapping with the strategy's address as the key
    const strategyParams = await strategyManagerPackage.attach(strategyManager.target).strategies(strategy.target);

    console.log("Activation Timestamp:", strategyParams.activation.toString());
    console.log("Last Report Timestamp:", strategyParams.lastReport.toString());
    console.log("Current Debt:", strategyParams.currentDebt.toString());
    console.log("Max Debt:", strategyParams.maxDebt.toString());

    await strategy.connect(owner).setMaxDebt(ethers.MaxUint256);

    return strategyParams;
}

async function addDebtToStrategy(owner, strategy, vaultPackage, vault, maxDebt, debt, strategyManagerPackage, strategyManager, strategyParams, sharesManager) {
    await expect(vaultPackage.attach(vault.target).connect(owner).updateMaxDebtForStrategy(strategy.target, maxDebt))
        .to.emit(strategyManagerPackage.attach(strategyManager.target), 'UpdatedMaxDebtForStrategy')
        .withArgs(owner.address, strategy.target, maxDebt);
    await expect(vaultPackage.attach(vault.target).connect(owner).updateDebt(sharesManager.target, strategy.target, debt))
        .to.emit(strategyManagerPackage.attach(strategyManager.target), 'DebtUpdated')
        .withArgs(strategy.target, strategyParams.currentDebt, debt);
}

async function initialSetup(asset, vaultPackage, vault, owner, maxDebt, debt, amount, strategyManagerPackage, strategyManager, sharesManagerPackage, sharesManager, profitMaxUnlockTime) {
    await asset.connect(owner).mint(owner.address, amount);
    const strategy = await createStrategy(owner, sharesManagerPackage, sharesManager, profitMaxUnlockTime);
    
    // Deposit assets to vault and get strategy ready
    await userDeposit(owner, vault, asset, amount, sharesManagerPackage, sharesManager);
    const strategyParams = await addStrategyToVault(owner, strategy, vaultPackage, vault, strategyManagerPackage, strategyManager);
    await addDebtToStrategy(owner, strategy, vaultPackage, vault, maxDebt, debt, strategyManagerPackage, strategyManager, strategyParams, sharesManager);

    return strategy;
}

module.exports = { userDeposit, checkVaultEmpty, createProfit, createStrategy, addStrategyToVault, addDebtToStrategy, initialSetup };
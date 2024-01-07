module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    const asset = "0x"; // Real asset address

    console.log("WARN: Ensure You set real asset address!!!");
    console.log("WARN: Ensure BaseStrategy has tokenizedStrategyAddress as constant!!!");
    console.log("WARN: Ensure InvestorStrategy has Investor address as constant!!!");
    
    console.log("Sleeping for 60 seconds to give a thought...");
    await new Promise(r => setTimeout(r, 60000));

    const investorAddress = investorFile.address;
    const investor = await ethers.getContractAt("Investor", investorAddress);

    const strategy = await deploy("InvestorStrategy", {
        from: deployer,
        args: [investorAddress, asset, "Fathom Investor Strategy 1"],
        log: true,
    });

    const setInvestorStrategyTx = await investor.setStrategy(strategy.address);
    await setInvestorStrategyTx.wait();
};

module.exports.tags = ["InvestorStrategy"];

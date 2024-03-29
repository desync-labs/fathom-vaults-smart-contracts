module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    console.log("WARN: Ensure TokenizedStrategy has FACTORY address as constant!!!");
    console.log("WARN: Ensure TokenizedStrategy has the correct profitMaxUnlockTime in constructor!!!");
    console.log("Sleeping for 60 seconds to give a thought...");
    await new Promise(r => setTimeout(r, 60000));

    const strategy = await deploy("TokenizedStrategy", {
        from: deployer,
        args: [],
        log: true,
    });
};

module.exports.tags = ["TokenizedStrategy"];

module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  const assetAddress = '0xDf29cB40Cb92a1b8E8337F542E3846E185DefF96'; // FXD Token on Apothem
  const vaultName = 'FathomVault';
  const vaultSymbol = 'FTHVT';
  const vaultDecimals = 18;
  const profitMaxUnlockTime = 31536000; // 1 year in seconds

  const asset = await deploy('Token', {
    from: deployer,
    args: [
      vaultSymbol,
      vaultDecimals
    ],
    log: true,
  });

  const strategyManager = await deploy('StrategyManager', {
    from: deployer,
    args: [
      asset.address
    ],
    log: true,
  });

  await deploy('FathomVault', {
    from: deployer,
    args: [
      asset.address,
      vaultName,
      vaultSymbol,
      vaultDecimals,
      profitMaxUnlockTime,
      strategyManager.address
    ],
    log: true,
  });
};

module.exports.tags = ['FathomVault'];

module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  const assetAddress = '0xDf29cB40Cb92a1b8E8337F542E3846E185DefF96'; // FXD Token on Apothem
  const vaultName = 'FathomVault';
  const vaultSymbol = 'FTHVT';
  const roleManagerAddress = '0x0db96Eb1dc48554bB0f8203A6dE449B2FcCF51a6';
  const profitMaxUnlockTime = 31536000; // 1 year in seconds
  const strategyManagerAddress = '0x0db96Eb1dc48554bB0f8203A6dE449B2FcCF51a6';

  await deploy('FathomVault', {
    from: deployer,
    args: [
      assetAddress,
      vaultName,
      vaultSymbol,
      roleManagerAddress,
      profitMaxUnlockTime,
      strategyManagerAddress
    ],
    log: true,
  });
};

module.exports.tags = ['FathomVault'];

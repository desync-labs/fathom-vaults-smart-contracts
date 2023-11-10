require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-ethers");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.16",
    settings: {
      optimizer: {
        enabled: true,
        runs: 10,
        details: { yul: false },
      }
    }
  },
  networks: {
  },
  namedAccounts: {
    deployer: 0,
  },
  paths: {
    deploy: './scripts/temp_migration',
  },
};
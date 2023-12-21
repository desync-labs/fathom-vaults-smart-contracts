require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-ethers");
require("hardhat-deploy");
const fs = require("fs");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    solidity: {
        version: "0.8.16",
        settings: {
            optimizer: {
                enabled: true,
                runs: 10,
                details: { yul: false },
            },
        },
    },
    networks: {
        apothem: {
            url: `https://earpc.apothem.network`,
            accounts: [fs.readFileSync("./privateKey").toString()],
        },
        ganache: {
            url: `http://127.0.0.1:8545`,
            accounts: [fs.readFileSync("./privateKey").toString()],
        },
        // hardhat: {
        //     forking: {
        //         url: "http://127.0.0.1:8545",
        //         accounts: [fs.readFileSync("./privateKey").toString()],
        //     },
        // },
    },
    namedAccounts: {
        deployer: 0,
    },
    paths: {
        deploy: "./scripts/",
    },
};

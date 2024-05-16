require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-ethers");
require("hardhat-deploy");
const fs = require("fs");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    solidity: {
        version: "0.8.19",
        settings: {
            optimizer: {
                enabled: true,
                runs: 5,
                details: { yul: true },
            },
        },
    },
    networks: {
        apothem: {
            url: `https://earpc.apothem.network`,
            // url: 'https://erpc.apothem.network',
            accounts: [fs.readFileSync("./privateKey").toString()],
        },
        xdc: {
            url: `https://erpc.xdcrpc.com`,
            accounts: [fs.readFileSync("./privateKey").toString()],
        },
        ganache: {
            url: `http://127.0.0.1:8545`,
            accounts: [fs.readFileSync("./privateKey").toString()],
        },
        localhost: {
            url: `http://127.0.0.1:8545`,
            accounts: [fs.readFileSync("./privateKey").toString()],
        },
        // hardhat: {
        //     accounts: {
        //         // 1 million ETH in wei
        //         count: 3,
        //         initialBalance: '1000000000000000000000000',
        //     },
        //     forking: {
        //         url: "https://earpc.xinfin.network"
        //     }
        // },
    },
    namedAccounts: {
        deployer: 0,
    },
    paths: {
        deploy: "./deploy/",
    },
};

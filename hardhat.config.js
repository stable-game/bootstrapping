require("@nomiclabs/hardhat-truffle5");
require("@nomiclabs/hardhat-ethers");
require("@nomiclabs/hardhat-etherscan");
require("solidity-coverage");
require("hardhat-gas-reporter");

const fs = require('fs')

module.exports = {
    solidity: {
        compilers: [
            {
                version: "0.6.11",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200
                    }
                }
            },
        ]
    },
    networks: {
        hardhat: {
            gas: 10000000,  // tx gas limit
            blockGasLimit: 12500000, 
            gasPrice: 20000000000,
            hardfork: 'berlin',
            allowUnlimitedContractSize: true
        }
    },
    mocha: { timeout: 12000000 },
    rpc: {
        host: "localhost",
        port: 8545
    },
    gasReporter: {
        enabled: (process.env.REPORT_GAS) ? true : false
    }
};

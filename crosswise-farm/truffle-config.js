require('dotenv').config();
const HDWalletProvider = require('@truffle/hdwallet-provider');
const web3 = require('web3');
const fs = require('fs');

let MEMO = process.env.PRIVATEKEY;
if( ! MEMO ){
  MEMO = fs.readFileSync("/media/veracrypt1/testnet/privateKey").toString().trim();
}

let BSCSCAN_API_KEY = process.env.BSCSCAN_API_KEY;
if( ! BSCSCAN_API_KEY ){
  BSCSCAN_API_KEY = fs.readFileSync("/media/veracrypt1/testnet/bscscan").toString().trim();
}

module.exports = {
  networks: {
    dev: {
      host: "127.0.0.1",
      port: 7545,
      network_id: '*'
    },
    mainnet: {
      provider: () => new HDWalletProvider(MEMO, `https://bsc-dataseed.binance.org/`),
      network_id: 56,
      confirmations: 2,
      timeoutBlocks: 10000,
      gasPrice: 20000000000,
      skipDryRun: true
    },
    testnet: {
      provider: () => new HDWalletProvider(MEMO, `https://data-seed-prebsc-1-s1.binance.org:8545/`),
      network_id: 97,
      confirmations: 2,
      gasPrice: 20000000000,
      timeoutBlocks: 10000,
      skipDryRun: true,
      networkCheckTimeout:999999
    }
  },
  plugins: [
    'truffle-plugin-verify',
    'solidity-coverage'
  ],
  api_keys: {
    bscscan: BSCSCAN_API_KEY
  },
  // Set default mocha options here, use special reporters etc.
  mocha: {
     timeout: 300000
  },

  // Configure your compilers
  compilers: {
    solc: {
      version: "0.6.12",    // Fetch exact version from solc-bin (default: truffle's version)
      settings: {          // See the solidity docs for advice about optimization and evmVersion
        optimizer: {
          enabled: true,
          runs: 200
       },
       evmVersion: "istanbul"
      }
    }
  }
};

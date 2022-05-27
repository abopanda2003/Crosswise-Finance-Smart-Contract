import "@nomiclabs/hardhat-waffle";
import "@typechain/hardhat";
import "hardhat-gas-reporter";
import "solidity-coverage";
import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-ethers";
import "hardhat-deploy";

import { resolve } from "path";

import { config as dotenvConfig } from "dotenv";
import { HardhatUserConfig } from "hardhat/config";

dotenvConfig({ path: resolve(__dirname, "./.env") });

const privateKey: string | undefined = process.env.PRIVATE_KEY ?? "NO_PRIVATE_KEY";

const config: HardhatUserConfig = {
	networks: {
		hardhat: {
			gasPrice: "auto",
			gasMultiplier: 2
		},
		localnet: {	// Ganache etc.
			url: "http://127.0.0.1:8545",
			gasPrice: "auto",
			gasMultiplier: 2
		},
		mainnet: {
			url: `https://speedy-nodes-nyc.moralis.io/fbb4b2b82993bf507eaaab13/bsc/mainnet`,
			accounts: [`0x${privateKey}`],
		},
		testnet: {
			url: `https://speedy-nodes-nyc.moralis.io/fbb4b2b82993bf507eaaab13/bsc/testnet/archive`,
			accounts: [`0x${privateKey}`],
		},
		fantomtestnet: {
			url: "https://rpc.testnet.fantom.network",
			accounts: [`0x${privateKey}`],
			chainId: 4002,
			gasPrice: "auto",
			gasMultiplier: 2
		},
	},
	paths: {
		artifacts: "./artifacts",
		cache: "./cache",
		sources: "./contracts",
		tests: "./test",
		deployments: "./deployments",
	},
	solidity: {
		compilers: [
			{
				version: "0.6.6",
				settings: {
					optimizer: {
						enabled: true,
						runs: 2,
					},
				}
			}
		],
	},
	mocha: {
		timeout: 200000
	}
};


export default config;

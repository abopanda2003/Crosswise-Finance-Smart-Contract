// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ethers, network, run } from "hardhat";
import { NomicLabsHardhatPluginError } from "hardhat/plugins";
import config from "../config";

async function main() {
  const signers = await ethers.getSigners();
  // Find deployer signer in signers.
  let deployer: SignerWithAddress | undefined;
  signers.forEach((a) => {
    if (a.address === process.env.ADDRESS) {
      deployer = a;
    }
  });
  if (!deployer) {
    throw new Error(`${process.env.ADDRESS} not found in signers!`);
  }

  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Network:", network.name);

  if (network.name === "testnet" || network.name === "mainnet") {
    const blockNumber = (await ethers.provider.getBlockNumber()) + 100;

    const SousChef = await ethers.getContractFactory("SousChef");
    const sousChef = await SousChef.deploy(
      config.StakingAddress,
      config.RewardAddress,
      ethers.BigNumber.from(10).pow(ethers.BigNumber.from(18)).div(10000), // 0.0001 eth
      blockNumber,
      blockNumber + 57600
    );

    console.log("Deployed SousChef Address: " + sousChef.address);

    try {
      // Verify
      console.log("Verifying SousChef: ", sousChef.address);
      await run("verify:verify", {
        address: sousChef.address,
        constructorArguments: [
          config.StakingAddress,
          config.RewardAddress,
          ethers.BigNumber.from(10).pow(ethers.BigNumber.from(18)).div(10000), // 0.0001 eth
          blockNumber,
          blockNumber + 57600,
        ],
      });
    } catch (error) {
      if (error instanceof NomicLabsHardhatPluginError) {
        console.log("Contract source code already verified");
      } else {
        console.error(error);
      }
    }

    const deployerLog = { Label: "Deploying Address", Info: deployer.address };
    const deployLog = {
      Label: "Deployed and Verified SousChef Address",
      Info: sousChef.address,
    };

    console.table([deployerLog, deployLog]);
  }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

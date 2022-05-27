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
    const CrssToken = await ethers.getContractFactory("CrssToken");
    const crssToken = await CrssToken.deploy(
      config.DevAddress,
      config.BuybackAddress,
      config.PresaleCrss[network.name],
      config.CrssV1[network.name]
    );
    await crssToken.deployed();

    console.log("Deployed CrssToken Address: " + crssToken.address);

    try {
      // Verify
      console.log("Verifying CrssToken: ", crssToken.address);
      await run("verify:verify", {
        address: crssToken.address,
        constructorArguments: [
          config.DevAddress,
          config.BuybackAddress,
          config.PresaleCrss[network.name],
          config.CrssV1[network.name],
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
      Label: "Deployed and Verified CrssToken Address",
      Info: crssToken.address,
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

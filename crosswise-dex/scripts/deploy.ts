import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ethers, network } from "hardhat";
import config from "./config";
import { deployCrss, deployFactory, deployFarm, deployRouter, deployXCrss } from "./feature/deploy";

async function main() {
  const signers = await ethers.getSigners();
  // Find deployer signer in signers.
  let deployer: SignerWithAddress | undefined;
  signers.forEach((a: any) => {
    if (a.address === process.env.DEPLOYER_ADDRESS) {
      deployer = a;
    }
  });
  if (!deployer) {
    throw new Error(`${process.env.DEPLOYER_ADDRESS} not found in signers!`);
  }

  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Network:", network.name);

  // Quit if networks are not supported
  if (network.name !== "bsc_testnet" && network.name !== "bsc_mainnet") {
    console.log("Network name is not supported");
    return;
  }

  const conf = config[network.name];

  const factory = await deployFactory(deployer, deployer.address);

  const router = await deployRouter(deployer, factory.address, conf.wbnb);

  const crss = await deployCrss(
    deployer,
    router.address,
    config.devAddress,
    config.buybackAddress,
    ethers.utils.parseEther("1000000") // config.liquifyThreshold
  );

  const startBlock = await ethers.provider.getBlockNumber();
  const farm = await deployFarm(
    deployer,
    crss.address,
    router.address,
    config.devAddress,
    conf.crssPerBlock,
    startBlock
  );

  const xcrss = await deployXCrss(deployer, crss.address);

  // configuration after deploy
  console.log("Start configuration after deployment");

  await factory.setRouter(router.address);
  console.log("Set router address in factory");

  await router.setCrssContract(crss.address);
  console.log("Set crss address in router");

  await crss.setFarm(farm.address);
  console.log("Set farm address in crss");

  await xcrss.setFarm(farm.address);
  console.log("Set farm address in xcrss");

  await farm.setXCrss(xcrss.address);
  console.log("Set xcrss address in farm");

  const deployerLog = { Label: "Deploying Address", Info: deployer.address };
  const deployLog = [
    {
      Label: "Deployed and Verified CrossFactory Address",
      Info: factory.address,
    },
    {
      Label: "Deployed and Verified CrossRouter Address",
      Info: router.address,
    },
    {
      Label: "Deployed and Verified CrssToken Address",
      Info: crss.address,
    },
    {
      Label: "Deployed and Verified xCrssToken Address",
      Info: xcrss.address,
    },
    {
      Label: "Deployed and Verified CrossFarm Address",
      Info: farm.address,
    },
  ];

  console.table([deployerLog, ...deployLog]);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

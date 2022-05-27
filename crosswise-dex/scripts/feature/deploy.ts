import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { BaseContract, BigNumber } from "ethers";
import { ethers, run, upgrades } from "hardhat";
import { NomicLabsHardhatPluginError } from "hardhat/plugins";
import { CrossFactory } from "../../types/CrossFactory";
import { CrossFarm } from "../../types/CrossFarm";
import { CrossRouter } from "../../types/CrossRouter";
import { CrssToken } from "../../types/CrssToken";
import { XCrssToken } from "../../types/XCrssToken";

export async function deployFactory(deployer: SignerWithAddress, feeToSetter: string): Promise<CrossFactory> {
  const Factory = await ethers.getContractFactory("CrossFactory");
  const factory = (await Factory.connect(deployer).deploy(feeToSetter)) as CrossFactory;
  await factory.deployed();
  console.log("Deployed CrossFactory: ", factory.address);

  try {
    // Verify
    console.log("Verifying CrossFactory: ", factory.address);
    await run("verify:verify", {
      address: factory.address,
      constructorArguments: [feeToSetter],
    });
  } catch (error) {
    if (error instanceof NomicLabsHardhatPluginError && error.message.includes("Reason: Already Verified")) {
      console.log("Already verified, skipping...");
    } else {
      console.error(error);
    }
  }

  return factory;
}

export async function deployRouter(deployer: SignerWithAddress, factory: string, wbnb: string): Promise<CrossRouter> {
  const Router = await ethers.getContractFactory("CrossRouter");
  const router = (await Router.connect(deployer).deploy(factory, wbnb)) as CrossRouter;
  await router.deployed();
  console.log("Deployed CrossRouter: ", router.address);

  try {
    // Verify
    console.log("Verifying CrossRouter: ", router.address);
    await run("verify:verify", {
      address: router.address,
      constructorArguments: [factory, wbnb],
    });
  } catch (error) {
    if (error instanceof NomicLabsHardhatPluginError && error.message.includes("Reason: Already Verified")) {
      console.log("Already verified, skipping...");
    } else {
      console.error(error);
    }
  }

  return router;
}

export async function deployCrss(
  deployer: SignerWithAddress,
  router: string,
  devTo: string,
  buybackTo: string,
  liquidityThreshold: number | BigNumber | string
): Promise<CrssToken> {
  const CrssToken = await ethers.getContractFactory("CrssToken", {
    signer: deployer,
  });
  const crssTokenUpgrades = (await upgrades.deployProxy(CrssToken, [
    router,
    devTo,
    buybackTo,
    liquidityThreshold,
  ])) as CrssToken;
  await crssTokenUpgrades.deployed();
  console.log("Deployed CrssToken: ", crssTokenUpgrades.address);

  try {
    // Verify
    const crssTokenImpl = await upgrades.erc1967.getImplementationAddress(crssTokenUpgrades.address);
    console.log("Verifying CrssToken: ", crssTokenImpl);
    await run("verify:verify", {
      address: crssTokenImpl,
    });
  } catch (error) {
    if (error instanceof NomicLabsHardhatPluginError && error.message.includes("Reason: Already Verified")) {
      console.log("Already verified, skipping...");
    } else {
      console.error(error);
    }
  }

  return crssTokenUpgrades;
}

export async function deployCrssVault(
  crssV1d1: string,
  xCrss: string,
  masterChef: string,
  devAddress: string
): Promise<BaseContract> {
  const CrssVault = await ethers.getContractFactory("CrssVault");
  const crssVault = await CrssVault.deploy(crssV1d1, xCrss, masterChef, devAddress);
  await crssVault.deployed();
  console.log("Deployed CrssVault: ", crssVault.address);

  try {
    // Verify
    console.log("Verifying CrssToken: ", crssVault.address);
    await run("verify:verify", {
      address: crssVault.address,
      constructorArguments: [crssV1d1, xCrss, masterChef, devAddress],
    });
  } catch (error) {
    if (error instanceof NomicLabsHardhatPluginError && error.message.includes("Reason: Already Verified")) {
      console.log("Already verified, skipping...");
    } else {
      console.error(error);
    }
  }

  return crssVault;
}

export async function deployFarm(
  deployer: SignerWithAddress,
  crss: string,
  // xCrss: string,
  router: string,
  devAddress: string,
  crssPerBlock: string,
  startBlock: number
): Promise<CrossFarm> {
  const CrossFarm = await ethers.getContractFactory("CrossFarm", {
    signer: deployer,
  });
  const crossFarmUpgrades = (await upgrades.deployProxy(CrossFarm, [
    crss,
    // xCrss,
    devAddress,
    router,
    crssPerBlock,
    startBlock,
  ])) as CrossFarm;
  await crossFarmUpgrades.deployed();

  console.log("Deployed CrossFarm Address: " + crossFarmUpgrades.address);

  try {
    // Verify
    const crossFarmImpl = await upgrades.erc1967.getImplementationAddress(crossFarmUpgrades.address);
    console.log("Verifying CrossFarm: ", crossFarmImpl);
    await run("verify:verify", {
      address: crossFarmImpl,
    });
  } catch (error) {
    if (error instanceof NomicLabsHardhatPluginError && error.message.includes("Reason: Already Verified")) {
      console.log("Already verified, skipping...");
    } else {
      console.error(error);
    }
  }

  return crossFarmUpgrades;
}

export async function deploySousChef(
  stakingAddress: string,
  rewardAddress: string,
  rewardPerBlock: BigNumber,
  startBlock: number,
  endBlock: number
): Promise<BaseContract> {
  const SousChef = await ethers.getContractFactory("SousChef");
  const sousChef = await SousChef.deploy(stakingAddress, rewardAddress, rewardPerBlock, startBlock, endBlock);
  console.log("Deployed SousChef Address: " + sousChef.address);

  try {
    // Verify
    console.log("Verifying SousChef: ", sousChef.address);
    await run("verify:verify", {
      address: sousChef.address,
      constructorArguments: [stakingAddress, rewardAddress, rewardPerBlock, startBlock, endBlock],
    });
  } catch (error) {
    if (error instanceof NomicLabsHardhatPluginError && error.message.includes("Reason: Already Verified")) {
      console.log("Already verified, skipping...");
    } else {
      console.error(error);
    }
  }

  return sousChef;
}

export async function deployXCrss(deployer: SignerWithAddress, crss: string): Promise<XCrssToken> {
  const XCrssToken = await ethers.getContractFactory("xCrssToken", {
    signer: deployer,
  });
  const xcrssTokenUpgrades = (await upgrades.deployProxy(XCrssToken, [crss])) as XCrssToken;
  await xcrssTokenUpgrades.deployed();
  console.log("Deployed XCrssToken: ", xcrssTokenUpgrades.address);

  try {
    // Verify
    const xcrssTokenImpl = await upgrades.erc1967.getImplementationAddress(xcrssTokenUpgrades.address);
    console.log("Verifying XCrssToken: ", xcrssTokenImpl);
    await run("verify:verify", {
      address: xcrssTokenImpl,
    });
  } catch (error) {
    if (error instanceof NomicLabsHardhatPluginError && error.message.includes("Reason: Already Verified")) {
      console.log("Already verified, skipping...");
    } else {
      console.error(error);
    }
  }

  return xcrssTokenUpgrades;
}

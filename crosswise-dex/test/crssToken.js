async function main() {
    const { ethers, upgrades } = require("hardhat");
  
    const [deployer, alice, bob, carol] = await ethers.getSigners();
  
    /***********************
  
    *      DEPLOY START

    ************************/
  
    const Factory = await ethers.getContractFactory("CrossFactory");
    const factory = await Factory.deploy(deployer.address);
  
    console.log("\nFactory Deployed: ", factory.address);
  
    const Router = await ethers.getContractFactory("CrossRouter");
    const router = await Router.deploy(factory.address, carol.address);
  
    console.log("\nRouter Deployed: ", router.address);
  
    factory.setRouter(router.address);
    console.log("\nFactory Router Set: ", router.address);
  
    const Crss = await ethers.getContractFactory("CrssToken");
    const crss = await upgrades.deployProxy(Crss, [router.address]);
  
    console.log("\nCrssToken Deployed: ", crss.address);
  
    router.setCrssContract(crss.address);
    console.log("\nCRSS token is set on Router:", crss.address);
  
    const crssPerBlock = 100;
    const startBlock = 123456;
    const CrossFarm = await ethers.getContractFactory("CrossFarm");
    const farm = await upgrades.deployProxy(CrossFarm, [
      crss.address,
      alice.address,
      router.address,
      crssPerBlock,
      startBlock,
    ]);
  
    console.log("\nFarm deployed: ", farm.address);
  
    await crss.setFarm(farm.address);
    console.log("\nFarm is set on CRSS: ", farm.address)
  
  }
  
  main((err) => {
    if (err) {
      console.log(err);
    }
  });
  
async function main() {
  const { ethers, upgrades } = require("hardhat");
  const { utils } = require("ethers");

  const [deployer, alice, bob, carol] = await ethers.getSigners();

  devTo = alice.address;
  buybackTo = bob.address;
  treasuryAddr = carol.address;

  /***********************
   *      DEPLOY START
   ************************/

  
  // Deploy Factory
  const Factory = await ethers.getContractFactory("CrossFactory");
  factory = await Factory.deploy(deployer.address);

  console.log("\nFactory Deployed: ", factory.address);

  // Deploy WBNB
  const WBNB = await ethers.getContractFactory("WBNB");
  wbnb = await WBNB.deploy();

  // Deploy Router
  const Router = await ethers.getContractFactory("CrossRouter");
  router = await Router.deploy(factory.address, wbnb.address);

  console.log("\nRouter Deployed: ", router.address);

  // Set Router on Factory
  factory.setRouter(router.address);
  console.log("\nFactory Router Set: ", router.address);

  // Set Liquify Threshold to 100 Crss and deploy Crss
  const thr = utils.parseEther("100");
  const Crss = await ethers.getContractFactory("CrssToken");
  crss = await upgrades.deployProxy(Crss, [router.address, devTo, buybackTo, thr]);

  console.log("\nCrssToken Deployed: ", crss.address);

  // Set Crss to Router
  router.setCrssContract(crss.address);
  console.log("\nCRSS token is set on Router:", crss.address);

  // Deploy Farm
  const crssPerBlock = "100";
  startBlock = await ethers.provider.getBlock("latest");
  const CrossFarm = await ethers.getContractFactory("CrossFarm");
  farm = await upgrades.deployProxy(CrossFarm, [
    crss.address,
    devTo,
    treasuryAddr,
    router.address,
    utils.parseEther(crssPerBlock),
    startBlock.number,
  ]);

  console.log("\nFarm deployed: ", farm.address);

  // Deploy XCrss
  const xCrss = await ethers.getContractFactory("xCrssToken");
  xcrss = await upgrades.deployProxy(xCrss, [router.address]);

  console.log("\nXCrssToken deployed: ", xcrss.address);

  // Deploy Referral
  const Referral = await ethers.getContractFactory("CrssReferral");
  referral = await upgrades.deployProxy(Referral, []);
  console.log("CrossReferral Deployed: ", referral.address);

  // Let Farm, Crss, XCrss know each other
  await farm.setXCrss(xcrss.address);
  await farm.setCrssReferral(referral.address);
  await xcrss.setFarm(farm.address);
  await crss.setFarm(farm.address);

  /***********************
   *      UPGRADE START
   ************************/

  const Crss2 = await ethers.getContractFactory("CrssToken2");
  const crss2 = await upgrades.upgradeProxy(crss.address, Crss2);

  console.log("\nCrssToken Upgraded: ", await crss2.getVersion());

  const xCrss2 = await ethers.getContractFactory("xCrssToken2");
  const xcrss2 = await upgrades.upgradeProxy(xcrss.address, xCrss2);

  console.log("\nxCrssToken Upgraded: ", await xcrss2.getVersion());

  const Farm2 = await ethers.getContractFactory("CrossFarm2");
  const farm2 = await upgrades.upgradeProxy(farm.address, Farm2);

  console.log("\nFarm Upgraded: ", await farm2.getVersion());
}

main((err) => {
  if (err) {
    console.log(err);
  }
});

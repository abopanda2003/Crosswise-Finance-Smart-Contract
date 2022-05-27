const { ethers, waffle, network, upgrades } = require("hardhat");
const { expect, util } = require("chai");
//const { FakeContract, smock } = require("@defi-wonderland/smock");

const { utils } = require("ethers");
const { abi: pairAbi } = require("../artifacts/contracts/core/CrossPair.sol/CrossPair.json");

// Address of contract and users that will be used globally
let factory,
  router,
  wbnb,
  crss,
  farm,
  xcrss,
  mock,
  referral,
  crss_mockPair,
  crss_ethPair,
  devTo,
  buybackTo,
  CrssBnbLP,
  CrssMCKLP,
  startBlock;

// Magnifier that is used in the contract
const FeeMagnifier = 10000;

// Crss-Mock Deposite Fee
const crss_mck_DF = 50;

// Crss-ETH Deposite Fee
const crss_eth_DF = 25;

describe("Cross Comprehensive Test", async () => {
  /**
   * Everything in this block is only run once before all tests.
   * This is the home for setup methodss
   */

  before(async () => {
    [deployer, alice, bob, carol] = await ethers.getSigners();

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
    console.log("\nXCRSS token is set on Farm: ", xcrss.address);

    // Deploy MockToken
    const MockToken = await ethers.getContractFactory("MockToken");
    mock = await MockToken.deploy("Mock", "MCK");
    console.log("\nmock token deployed: ", mock.address);

    console.log("\nFactory Code Hash: ", await factory.INIT_CODE_PAIR_HASH());
    console.log("\nTesting Start\n");
  });

  describe("Farming Basic Test - isAuto == true, isVest == true", async () => {
    it("Approve Crss to Router", async () => {
      await crss.approve(router.address, utils.parseEther("1000000"));
      expect(await crss.allowance(deployer.address, router.address)).to.equal(utils.parseEther("1000000"));
    });

    it("Mint MCK and approve it to router", async () => {
      await mock.mint(deployer.address, utils.parseEther("500000"));
      await mock.approve(router.address, utils.parseEther("500000"));
      expect(await mock.allowance(deployer.address, router.address)).to.equal(utils.parseEther("500000"));
    });

    it("Crss-MCK LP Balance should be the same as calculated", async () => {
      // Add Liquidify Financial Check
      const block = await ethers.provider.getBlock("latest");
      await router.addLiquidity(
        crss.address,
        mock.address,
        utils.parseEther("50"),
        utils.parseEther("50"),
        0,
        0,
        deployer.address,
        block.timestamp + 1000
      );

      const pairAddr = await factory.getPair(crss.address, mock.address);
      crss_mockPair = new ethers.Contract(pairAddr, pairAbi, deployer);

      // LP Balance that deployer received
      const lpBalance = await crss_mockPair.balanceOf(deployer.address);

      // LP Balance that is calculated outside
      CrssMCKLP = sqrt(utils.parseEther("50").mul(utils.parseEther("50").mul(999).div(1000)));
      expect(lpBalance).to.equal(CrssMCKLP.sub(1000));
    });

    it("Crss-BNB LP Balance should be 10000", async () => {
      // Add Liquidity Ether Financial Check
      const block = await ethers.provider.getBlock("latest");
      await router.addLiquidityETH(
        crss.address,
        utils.parseEther("100000"),
        0,
        0,
        deployer.address,
        block.timestamp + 1000,
        {
          value: utils.parseEther("1000"),
        }
      );

      const pairAddr = await factory.getPair(crss.address, wbnb.address);
      crss_ethPair = new ethers.Contract(pairAddr, pairAbi, deployer);

      // LP Balance that deployer received
      const lpBalance = await crss_ethPair.balanceOf(deployer.address);

      // LP Balance that is calculated outside
      CrssBnbLP = sqrt(utils.parseEther("1000").mul(utils.parseEther("100000").mul(999).div(1000)));
      expect(lpBalance).to.equal(CrssBnbLP.sub(1000));
    });

    it("Add Crss-MCK LP to Farm", async () => {
      const pairAddr = await factory.getPair(crss.address, mock.address);
      await farm.add(100, pairAddr, false, crss_mck_DF, "0x0000000000000000000000000000000000000000");
      expect(await farm.poolLength()).to.equal(2);
    });

    it("Add Crss-ETH LP to Farm", async () => {
      const pairAddr = await factory.getPair(crss.address, wbnb.address);
      await farm.add(100, pairAddr, false, crss_eth_DF, "0x0000000000000000000000000000000000000000");
      expect(await farm.poolLength()).to.equal(3);
    });

    it("Revert Crss-ETH LP to Farm", async () => {
      const pairAddr = await factory.getPair(crss.address, wbnb.address);
      await expect(farm.add(100, pairAddr, false, crss_eth_DF, "0x0000000000000000000000000000000000000000")).to.be.revertedWith("Cross: Not allowed to duplicate LP token");
    });

    it("Approve Crss-Mock LP", async () => {
      const lpBalance = await crss_mockPair.balanceOf(deployer.address);
      await crss_mockPair.approve(farm.address, lpBalance);
      expect(await crss_mockPair.allowance(deployer.address, farm.address)).to.equal(lpBalance);
    });

    // Deposit Crss-MCK Financial Check : pool id is 1
    it("Deposit Crss-MCK", async () => {
      // Calculate how much will be deposited
      const lpBalance = await crss_mockPair.balanceOf(deployer.address);
      const expected = lpBalance.mul(FeeMagnifier - crss_mck_DF).div(FeeMagnifier);
      await farm.deposit(1, lpBalance, true, "0x0000000000000000000000000000000000000000", true);
      const lpStaked = await farm.userInfo(1, deployer.address);
      expect(Number(utils.formatEther(expected)).toFixed(5)).to.equal(
        Number(utils.formatEther(lpStaked.amount)).toFixed(5)
      );
    });

    it("Approve Crss-BNB LP", async () => {
      const lpBalance = await crss_ethPair.balanceOf(deployer.address);
      await crss_ethPair.approve(farm.address, lpBalance);
      expect(await crss_ethPair.allowance(deployer.address, farm.address)).to.equal(lpBalance);
    });

    it("Update Crss Referral Operator", async () => {
      await referral.transferOwnership(farm.address);
      expect(await referral.owner()).to.equal(farm.address);
    });

    it("Deposit Crss-ETH", async () => {
      let lpBalance = await crss_ethPair.balanceOf(deployer.address);
      await farm.deposit(2, lpBalance, true, alice.address, false);
      lpBalance = await crss_ethPair.balanceOf(deployer.address);
      expect(lpBalance).to.equal(0);
    });

    it("Spend Block Time by 3600", async () => {
      await network.provider.send("evm_increaseTime", [36000]);
      await network.provider.send("evm_mine");
    });

    it("Pendign Crss for Crss-Mock staking", async () => {
      const pending = await farm.pendingCrss(1, deployer.address);
      // Need to be checked in financial terms
      console.log("Pending Amount: ", utils.formatEther(pending));
    });

    it("Deployer Crss-Mock Staking Result", async () => {
      // This will reverted, because there is not enough liquidity to provide the swap for autocompounding
      await expect(farm.earn(1)).to.revertedWith("TransferHelper: TRANSFER_FROM_FAILED");
    });

    it("Crss-MCK LP Balance should be", async () => {
      const block = await ethers.provider.getBlock("latest");
      await router.addLiquidity(
        crss.address,
        mock.address,
        utils.parseEther("300000"),
        utils.parseEther("300000"),
        0,
        0,
        deployer.address,
        block.timestamp + 1000
      );
    });

    // Earn Financial Check: Tested on Contract vision because of swap slippage
    it("Deployer Crss-Mock Staking Result", async () => {
      await farm.earn(1);
    });

    // To change tx origin to avoid trasaction wide amount check
    it("Transfer", async () => {
      await crss.connect(alice).transfer(bob.address, 1);
    });

    it("Referral Amount Check", async () => {
      const aliceBalOld = await crss.balanceOf(alice.address);
      await farm.earn(2);
      const aliceBalNew = await crss.balanceOf(alice.address);
      console.log("Referrer Amount is: ", utils.formatEther(aliceBalNew.sub(aliceBalOld)));
    });

    it("Spend Block Time by 3600", async () => {
      await network.provider.send("evm_increaseTime", [3600]);
      await network.provider.send("evm_mine");
    });

    it("Withdraw will be reverted because of exceed amount", async () => {
      const user = await farm.userInfo(1, deployer.address);
      await expect(farm.withdraw(1, user.amount.add(100000))).to.be.revertedWith("withdraw: not good");
    });

    it("Withdraw will succeed", async () => {
      const user = await farm.userInfo(1, deployer.address);
      let lpBalance = await crss_mockPair.balanceOf(deployer.address);
      await farm.withdraw(1, user.amount);
      let lpBalanceNew = await crss_mockPair.balanceOf(deployer.address);
      await expect(lpBalanceNew.sub(lpBalance)).to.be.equal(user.amount);
    });

    it("Spend Block Two Month", async () => {
      await network.provider.send("evm_increaseTime", [3600 * 24 * 60]);
      await network.provider.send("evm_mine");
    });

    it("Withdraw Vest", async () => {
      const user = await farm.userInfo(1, deployer.address);
      const vestAmount = await farm.totalWithDrawableVest(1);
      console.log("Withdrawable Vested Amount: ", utils.formatEther(vestAmount));
      // Need to be checked in financial terms
      const crssBalOld = await crss.balanceOf(deployer.address);
      await farm.withdrawVest(1, utils.parseEther("10"));
      const crssBalNew = await crss.balanceOf(deployer.address);
      expect(crssBalNew.sub(crssBalOld)).to.equal(utils.parseEther("10").mul(999).div(1000));
    });

    it("Emergency Withdraw", async () => {
      const user = await farm.userInfo(2, deployer.address);
      const crssBalOld = await crss_ethPair.balanceOf(deployer.address);
      await farm.emergencyWithdraw(2);
      const crssBalNew = await crss_ethPair.balanceOf(deployer.address);
      expect(crssBalNew.sub(crssBalOld)).to.equal(user.amount);
    });

    it("Approve Crss to Farm", async () => {
      await crss.approve(farm.address, utils.parseEther("100000"));
    });

    it("Enter Staking Crss, xCrss Result should be 999 Eth", async () => {
      await farm.enterStaking(utils.parseEther("1000"));
      const xcrssAmount = await xcrss.balanceOf(deployer.address);
      expect(xcrssAmount).to.equal(utils.parseEther("1000").mul(999).div(1000));
    });

    it("Pool0 Amount should be 999Eth", async () => {
      const user = await farm.userInfo(0, deployer.address);
      expect(user.amount).to.equal(utils.parseEther("1000").mul(999).div(1000))
    })

    it("Leave Staking Crss, xCrss is all burnt", async () => {
      const xcrssAmountOld = await xcrss.balanceOf(deployer.address);
      const crssAmountOld = await crss.balanceOf(deployer.address);
      await farm.leaveStaking(xcrssAmountOld);
      const xcrssAmountNew = await xcrss.balanceOf(deployer.address);
      const crssAmountNew = await crss.balanceOf(deployer.address);
      expect(xcrssAmountNew).to.equal(0);
    });

    it("Approve Crss-Mock LP", async () => {
      const lpBalance = await crss_mockPair.balanceOf(deployer.address);
      await crss_mockPair.approve(farm.address, lpBalance);
      expect(await crss_mockPair.allowance(deployer.address, farm.address)).to.equal(lpBalance);
    });

    it("Approve Crss to Farm", async () => {
      await crss.approve(farm.address, utils.parseEther("1000000"));
    });

    it("Enter Staking Crss, xCrss Result should be 999 Eth", async () => {
      await farm.enterStaking(utils.parseEther("1000"));
      const xcrssAmount = await xcrss.balanceOf(deployer.address);
      expect(xcrssAmount).to.equal(utils.parseEther("999"));
    });

    it("Approve Crss-BNB LP", async () => {
      const lpBalance = await crss_ethPair.balanceOf(deployer.address);
      await crss_ethPair.approve(farm.address, lpBalance);
      expect(await crss_ethPair.allowance(deployer.address, farm.address)).to.equal(lpBalance);
    });

    it("Deposit Crss-ETH", async () => {
      let lpBalance = await crss_ethPair.balanceOf(deployer.address);
      await farm.deposit(2, lpBalance, false, alice.address, false);
      lpBalance = await crss_ethPair.balanceOf(deployer.address);
      expect(lpBalance).to.equal(0);
    });

    it("Spend Block Time by 3600", async () => {
      await network.provider.send("evm_increaseTime", [3600]);
      await network.provider.send("evm_mine");
    });

    it("Mass Harvest", async () => {
      const crssBalOld = await crss.balanceOf(deployer.address);
      await farm.massHarvest([0, 1, 2]);
      const crssBalNew = await crss.balanceOf(deployer.address);
      console.log("Mass Harvested Result: ", utils.formatEther(crssBalNew.sub(crssBalOld)));
    });

    it("Spend Block Time by 3600", async () => {
      await network.provider.send("evm_increaseTime", [3600 * 24 * 60]);
      await network.provider.send("evm_mine");
    });

    it("Transfer", async () => {
      await crss.connect(alice).transfer(bob.address, 1);
    });

    it("Approve Crss to Farm", async () => {
      await crss.approve(farm.address, utils.parseEther("1000000"));
    });

    it("Mass Stake Reward", async () => {
      await farm.massStakeReward([0, 1, 2]);
    });
  });
});

async function delay() {
  return new Promise((resolve, reject) => {
    setTimeout(() => {
      resolve("OK");
    }, 5000);
  });
}

const ONE = ethers.BigNumber.from(1);
const TWO = ethers.BigNumber.from(2);

function sqrt(value) {
  x = value;
  let z = x.add(ONE).div(TWO);
  let y = x;
  while (z.sub(y).isNegative()) {
    y = z;
    z = x.div(z).add(z).div(TWO);
  }
  return y;
}

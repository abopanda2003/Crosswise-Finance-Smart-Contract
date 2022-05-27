import { expect } from "chai";
import hre, { deployments, ethers, waffle } from "hardhat";
import "@nomiclabs/hardhat-ethers";

import { CrossFactory } from "../types/CrossFactory";
import { CrossRouter } from "../types/CrossRouter";
import { CrssToken } from "../types/CrssToken";
import { XCrssToken } from "../types/XCrssToken";
import { CrossFarm } from "../types/CrossFarm";
import { WBNB as WBNBT } from "../types/WBNB";
import { MockToken } from "../types/MockToken";
import { MockTransfer } from "../types/MockTransfer";
import { expandTo18Decimals, mineBlocks, mineMoreBlock } from "./shared/utilities";

import CrossPairAbi from "../artifacts/contracts/core/CrossPair.sol/CrossPair.json";
import { CrossPair } from "../types/CrossPair";
import { BigNumber } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

const overrides = {
  gasLimit: 9999999,
};

describe("crossfarm test", async () => {
  let owner: SignerWithAddress,
    userA: SignerWithAddress,
    userB: SignerWithAddress,
    userC: SignerWithAddress,
    devTo: SignerWithAddress,
    buybackTo: SignerWithAddress;

  const setupTest = async () => {
    console.log("setupTest");

    const Factory = await hre.ethers.getContractFactory("CrossFactory");
    const factory = (await Factory.deploy(owner.address)) as CrossFactory;
    await factory.deployed();

    const WBNB = await hre.ethers.getContractFactory("WBNB");
    const wbnb = (await WBNB.deploy()) as WBNBT;
    await wbnb.deployed();

    const Router = await hre.ethers.getContractFactory("CrossRouter");
    const router = (await Router.deploy(factory.address, wbnb.address)) as CrossRouter;
    await router.deployed();

    // @notice, require to add in deploy script too
    await factory.setRouter(router.address);

    const liquifyThreshold = hre.ethers.utils.parseEther("100000");

    const Crss = await hre.ethers.getContractFactory("CrssToken");
    const crss = (await hre.upgrades.deployProxy(Crss, [
      router.address,
      devTo.address,
      buybackTo.address,
      liquifyThreshold,
    ])) as CrssToken;
    await crss.deployed();

    await router.setCrssContract(crss.address);

    const crssPerBlock = BigNumber.from(10).pow(17);
    const startBlock = await ethers.provider.getBlock("latest");
    const Farm = await hre.ethers.getContractFactory("CrossFarm");
    const farm = (await Farm.deploy()) as CrossFarm;
    await farm.initialize(crss.address, userA.address, userB.address, router.address, crssPerBlock, startBlock.number);
    await farm.deployed();

    const XCrss = await hre.ethers.getContractFactory("xCrssToken");
    const xCrss = (await hre.upgrades.deployProxy(XCrss, [crss.address])) as XCrssToken;
    await xCrss.deployed();

    await farm.setXCrss(xCrss.address);
    await crss.setFarm(farm.address);
    await xCrss.setFarm(farm.address);

    return {
      factory,
      router,
      crss,
      xCrss,
      farm,
    };
  };

  let factory: CrossFactory,
    router: CrossRouter,
    crss: CrssToken,
    xCrss: XCrssToken,
    farm: CrossFarm,
    tokenA: MockToken,
    pair: CrossPair,
    poolLength: number;

  before("setup", async () => {
    [owner, userA, userB, userC, devTo, buybackTo] = await ethers.getSigners();
    ({ factory, router, crss, xCrss, farm } = await setupTest());

    console.log("owner is minting itself for testing");
    await crss.connect(owner).setFarm(owner.address);
    await crss.connect(owner).mint(owner.address, expandTo18Decimals(10000));
    await crss.connect(owner).setFarm(farm.address);
  });

  describe("fee management", async () => {
    it("should have a function to set fee rate", async () => {
      // @todo
      expect(false).to.be.equal(true);
    });
  });

  async function addLP_CrssMock(mint: BigNumber) {
    const MockToken = await hre.ethers.getContractFactory("MockToken");
    const tokenA = (await MockToken.deploy("tokenA", "tokenA")) as MockToken;
    await tokenA.connect(owner).mint(owner.address, mint);

    await crss.approve(router.address, ethers.constants.MaxUint256);
    await tokenA.approve(router.address, ethers.constants.MaxUint256);

    await router.addLiquidity(
      crss.address,
      tokenA.address,
      mint,
      mint,
      0,
      0,
      owner.address,
      ethers.constants.MaxUint256
    );

    const pairAddress = await factory.getPair(crss.address, tokenA.address);
    const pair = (await hre.ethers.getContractAt(CrossPairAbi.abi, pairAddress, owner)) as CrossPair;

    return {
      crss,
      tokenA,
      pair,
      pairAddress,
    };
  }

  async function addLiquidity(amount: BigNumber) {
    await tokenA.connect(owner).mint(owner.address, amount);

    await crss.connect(owner).transfer(pair.address, amount);
    await tokenA.connect(owner).transfer(pair.address, amount);
    await pair.connect(owner).mint(owner.address, overrides);
  }

  describe("fundemental deposit/withdraw test", async () => {
    before("add liquidity", async () => {
      ({ tokenA, pair } = await addLP_CrssMock(expandTo18Decimals(1)));
      console.log("> pair.address", pair.address);
      await farm.add(100, pair.address, true, 0, ethers.constants.AddressZero);
      poolLength = (await farm.poolLength()).toNumber();
    });

    it("deposit test", async () => {
      const lpBalance = await pair.balanceOf(owner.address);
      await pair.connect(owner).approve(farm.address, ethers.constants.MaxUint256);
      await expect(farm.deposit(1, lpBalance, false, ethers.constants.AddressZero, false)).to.be.not.reverted;

      const userInfo = await farm.userInfo(1, owner.address);
      expect(userInfo.amount).to.be.equal(lpBalance);
    });

    it("withdraw test", async () => {
      const beforeBalance = await pair.balanceOf(owner.address);
      const userInfo = await farm.userInfo(1, owner.address);
      await expect(farm.withdraw(1, userInfo.amount)).to.be.not.reverted;
      const afterBalance = await pair.balanceOf(owner.address);
      const userInfoAfter = await farm.userInfo(1, owner.address);
      expect(userInfoAfter.amount).to.be.equal(0);
      expect(afterBalance.sub(beforeBalance)).to.be.equal(userInfo.amount);
    });
  });

  describe("vesting schedule test", async () => {
    beforeEach("add liquidity", async () => {
      ({ tokenA, pair } = await addLP_CrssMock(expandTo18Decimals(5)));
      console.log("> pair.address", pair.address);
      await farm.add(100, pair.address, true, 0, ethers.constants.AddressZero);
      poolLength = (await farm.poolLength()).toNumber();
      console.log("pool length", poolLength);

      console.log("owner is depositing on pool");
      await pair.connect(owner).approve(farm.address, ethers.constants.MaxUint256);
      const lpBalance = await pair.balanceOf(owner.address);
      await expect(farm.deposit(poolLength - 1, lpBalance, false, ethers.constants.AddressZero, true)).to.be.not
        .reverted;

      // add liquidity
      console.log("owner is adding liquidity");
      await addLiquidity(expandTo18Decimals(1));

      // pass 1 hour
      console.log("passing one hour");
      await mineBlocks(3000, 1200); // 1 hour: 1200 blocks

      // second deposit
      console.log("owner is depositing on pool again");
      const lpBalance2 = await pair.balanceOf(owner.address);
      await expect(farm.deposit(poolLength - 1, lpBalance2, false, ethers.constants.AddressZero, true)).to.be.not
        .reverted;
    });

    it("should have withdrawable vest amount if passed less than a month or if passed a month", async () => {
      // await mineBlocks(3000, 864000);
      await mineMoreBlock(2592000); // 30 days
      const totalVestOneMonth = await farm.totalWithDrawableVest(poolLength - 1);
      console.log("totalVestOneMonth", totalVestOneMonth.toString());
      expect(totalVestOneMonth).to.be.gt(0);

      for (let i = 0; i < 10; i++) {
        await mineMoreBlock(2592000); // 30 days
      }
      const totalVestFinal = await farm.totalWithDrawableVest(poolLength - 1);
      console.log("totalVestFinal", totalVestFinal.toString());
      expect(totalVestFinal).to.be.equal(totalVestOneMonth.mul(BigNumber.from(5)));
    });

    it("withdrawable vest amount should be", async () => {});

    it("should be able to withdraw vest again", async () => {
      // pass one month
      console.log("passing one month");
      await mineMoreBlock(2592000); // 30 days
      const totalVestOneMonth = await farm.totalWithDrawableVest(poolLength - 1);
      // check if totalVestList is not zero
      expect(totalVestOneMonth).to.be.gt(0);

      // withdraw once
      console.log("owner is withdrawing 1/5 of total vesting");
      await expect(farm.withdrawVest(poolLength - 1, totalVestOneMonth)).to.be.not.reverted;

      // check if totalVestList is null
      console.log("total vesting amount should be zero");
      const totalVestOneMonthAgain = await farm.totalWithDrawableVest(poolLength - 1);
      expect(totalVestOneMonthAgain).to.be.equal(0);

      // pass one month again
      console.log("passing one month again");
      await mineMoreBlock(2592000); // 30 days

      // check if totalVestList is not null and same with previous totalVestList
      console.log("checking if totalVestList is not null and same with previous totalVestList");
      const totalVestAfterWithdraw = await farm.totalWithDrawableVest(poolLength - 1);
      expect(totalVestOneMonth.sub(totalVestAfterWithdraw).abs()).to.be.lt(BigNumber.from(5));

      // pass 5 month
      for (let i = 0; i < 10; i++) {
        await mineMoreBlock(2592000); // 30 days
      }

      console.log("checking if totalVestList is 4 times of one months");
      const totalVest = await farm.totalWithDrawableVest(poolLength - 1);
      expect(totalVest.sub(totalVestOneMonth.mul(4)).abs()).to.be.lt(BigNumber.from(10));
    });

    it("how to test vestList.length because of delete", async () => {
      // @todo
      expect(false).to.be.equal(true);
    });

    it("how to test reentrancy attack in withdrawVest", async () => {
      // pass one month
      console.log("passing one month again");
      await mineMoreBlock(2592000); // 30 days
      const totalVestOneMonth = await farm.totalWithDrawableVest(poolLength - 1);
      // check if totalVestList is not zero
      expect(totalVestOneMonth).to.be.gt(0);

      const beforeBalance = await crss.balanceOf(owner.address);
      // withdraw once
      console.log("owner is withdrawing 1/5 of total vesting");
      await expect(farm.withdrawVest(poolLength - 1, totalVestOneMonth.mul(2))).to.be.revertedWith(
        "Cross: Requested amount exceeds the withdrawable amount"
      );
      const currentBalance = await crss.balanceOf(owner.address);
      expect(currentBalance.sub(beforeBalance)).to.be.equal(0);

      const MockTransfer = await hre.ethers.getContractFactory("MockTransfer");
      const mockTransfer = (await MockTransfer.deploy(crss.address)) as MockTransfer;

      await expect(mockTransfer.withdrawVest(farm.address, poolLength - 1, totalVestOneMonth)).to.be.revertedWith(
        "Cross: Requested amount exceeds the withdrawable amount"
      );
    });

    it("should withdraw vest less than unlocked amount", async () => {
      // should check amount if already unlocked and transfer
      // pass one hour
      console.log("passing one hour");
      await mineMoreBlock(3600); // 1 hour
      const totalVestOneHour = await farm.totalWithDrawableVest(poolLength - 1);
      // check if totalVestList is not zero
      expect(totalVestOneHour).to.be.equal(0);
    });

    it("should withdraw anytime after 5 months", async () => {
      // pass one month again
      console.log("passing one month");
      await mineMoreBlock(2592000); // 30 days

      // check if totalVestList is not null and same with previous totalVestList
      console.log("checking if totalVestList is not null and same with previous totalVestList");
      const totalVestOneMonth = await farm.totalWithDrawableVest(poolLength - 1);
      console.log("total vesting amount after 1 month", totalVestOneMonth.toString());

      // pass 5 month
      console.log("passing 10 months again");
      for (let i = 0; i < 10; i++) {
        await mineMoreBlock(2592000); // 30 days
      }

      console.log("checking a totalVestList");
      const totalVestTenMonth = await farm.totalWithDrawableVest(poolLength - 1);
      console.log("total vesting amount after 10 months", totalVestTenMonth.toString());

      console.log("total vesting amount should be 5 times of first month");
      expect(totalVestTenMonth.sub(totalVestOneMonth.mul(5)).abs()).to.be.lt(BigNumber.from(10));

      console.log("owner is withdrawing total vesting amount");
      await farm.withdrawVest(poolLength - 1, totalVestTenMonth);

      console.log("checking if it has remaining vesting amount");
      const totalVestAfterWithdraw = await farm.totalWithDrawableVest(poolLength - 1);
      console.log("totalVestAfterWithdraw", totalVestAfterWithdraw.toString());
      await expect(totalVestAfterWithdraw).to.be.equal(0);
    });
  });

  describe("deposit fee test", async () => {
    it("should not take deposit fee for pool 0", async () => {});

    it("should take deposit fee for lp pool", async () => {});

    it("deposit fee should transfer to dev & treasury", async () => {});
  });

  describe("deposit/withdraw test", async () => {
    beforeEach("add liquidity", async () => {
      ({ tokenA, pair } = await addLP_CrssMock(expandTo18Decimals(5)));
      console.log("> pair.address", pair.address);
      await farm.add(100, pair.address, true, 0, ethers.constants.AddressZero);
      poolLength = (await farm.poolLength()).toNumber();
      console.log("pool length", poolLength);
    });

    it("check if multiple deposit/one withdraw", async () => {
      console.log("owner is depositing on pool");
      await pair.connect(owner).approve(farm.address, ethers.constants.MaxUint256);
      const lpBalance = await pair.balanceOf(owner.address);
      await expect(farm.deposit(poolLength - 1, lpBalance, true, ethers.constants.AddressZero, true)).to.be.not
        .reverted;

      console.log("owner is depositing on pool again without adding liquidity");
      await expect(farm.deposit(poolLength - 1, lpBalance, true, ethers.constants.AddressZero, true)).to.be.reverted;

      let balance = BigNumber.from(0);
      for (let i = 0; i < 10; i++) {
        console.log("owner is adding liquidity");
        await addLiquidity(expandTo18Decimals(1));

        await mineBlocks(3000, 1200); // 1200 blocks, 1 hour

        console.log("owner is depositing on pool again");
        const lpBalance = await pair.balanceOf(owner.address);
        await farm.deposit(poolLength - 1, lpBalance, true, ethers.constants.AddressZero, true);

        balance = balance.add(lpBalance);
      }

      await mineBlocks(3000, 1200); // 1200 blocks, 1 hour

      console.log("owner is withdrawing from pool");
      await expect(farm.withdraw(poolLength - 1, lpBalance.add(balance))).to.be.not.reverted;

      const userInfo = await farm.userInfo(poolLength - 1, owner.address);
      expect(userInfo.amount).to.be.equal(0);
    });

    it("check enterStaking/leaveStaking", async () => {
      console.log("owner is approving crss to farm");
      await crss.approve(farm.address, expandTo18Decimals(1));
      console.log("owner is entering staking");
      await farm.enterStaking(expandTo18Decimals(1));

      console.log("owner is leaving staking");
      const userInfo = await farm.userInfo(0, owner.address);
      await farm.leaveStaking(userInfo.amount);

      console.log("user info should have empty");
      const userInfoAfter = await farm.userInfo(0, owner.address);
      expect(userInfoAfter.amount).to.be.equal(0);
    });

    it("compare emergencyWithdraw & enter/leaveStaking", async () => {
      const balanceBeforeEnterStaking = await crss.balanceOf(owner.address);
      console.log("owner is approving crss to farm");
      await crss.approve(farm.address, expandTo18Decimals(1));
      console.log("owner is entering staking");
      await farm.enterStaking(expandTo18Decimals(1));
      const userInfo = await farm.userInfo(0, owner.address);
      console.log("user amount after staking is", userInfo.amount.toString());

      const pendingCrss = await farm.pendingCrss(0, owner.address);

      console.log("owner is leaving staking");
      await farm.leaveStaking(userInfo.amount);

      const balanceAfterEnterStaking = await crss.balanceOf(owner.address);
      const returnedAfterEnterStaking = balanceBeforeEnterStaking.sub(balanceAfterEnterStaking);
      console.log("returned amount from leaveStaking is ", returnedAfterEnterStaking.toString());

      const balanceBeforeEnterStaking2 = await crss.balanceOf(owner.address);
      console.log("owner is approving crss to farm again");
      await crss.approve(farm.address, expandTo18Decimals(1));
      console.log("owner is entering staking again");
      await farm.enterStaking(expandTo18Decimals(1));
      const userInfo2 = await farm.userInfo(0, owner.address);
      console.log("user amount2 after staking is", userInfo2.amount.toString());

      console.log("owner is emergency withdrawing");
      await farm.emergencyWithdraw(0);

      const balanceAfterEnterStaking2 = await crss.balanceOf(owner.address);
      const returnedAfterEnterStaking2 = balanceBeforeEnterStaking2.sub(balanceAfterEnterStaking2);
      console.log("returned amount from emergencyWithdraw is ", returnedAfterEnterStaking2.toString());

      console.log("returned crss from leaveStaking should be same with emergencyWithdraw");
      expect(returnedAfterEnterStaking).to.be.equal(returnedAfterEnterStaking2);
    });
  });
});

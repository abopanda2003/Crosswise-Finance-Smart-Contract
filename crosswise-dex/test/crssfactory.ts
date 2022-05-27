import { expect } from "chai";

import hre, { deployments, ethers, waffle } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { BigNumber } from "ethers";

import { CrossFactory } from "../types/CrossFactory";
import { CrossRouter } from "../types/CrossRouter";
import { CrssToken } from "../types/CrssToken";
import { WBNB as WBNBT } from "../types/WBNB";
import { MockTransfer } from "../types/MockTransfer";
import { XCrssToken } from "../types/XCrssToken";
import { getCreate2Address } from "./shared/utilities";

import CrossPairAbi from "../artifacts/contracts/core/CrossPair.sol/CrossPair.json";
import { CrossPair } from "../types/CrossPair";

const TEST_ADDRESSES: [string, string] = [
  "0x1000000000000000000000000000000000000000",
  "0x2000000000000000000000000000000000000000",
];

describe("CrssFactory test", async () => {
  const [owner, userA, userB, userC, devTo, buybackTo] = waffle.provider.getWallets();

  const setupTest = deployments.createFixture(async ({ deployments }) => {
    await deployments.fixture();

    const Factory = await hre.ethers.getContractFactory("CrossFactory");
    const factory = (await Factory.deploy(owner.address)) as CrossFactory;
    await factory.deployed();

    const WBNB = await hre.ethers.getContractFactory("WBNB");
    const wbnb = (await WBNB.deploy()) as WBNBT;
    await wbnb.deployed();

    const Router = await hre.ethers.getContractFactory("CrossRouter");
    const router = (await Router.deploy(factory.address, wbnb.address)) as CrossRouter;
    await router.deployed();

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

    const XCrss = await hre.ethers.getContractFactory("xCrssToken");
    const xCrss = (await hre.upgrades.deployProxy(XCrss, [crss.address])) as XCrssToken;
    await xCrss.deployed();

    const MockTransfer = await hre.ethers.getContractFactory("MockTransfer");
    const mockTransfer = (await MockTransfer.deploy(crss.address)) as MockTransfer;
    await mockTransfer.deployed();

    return {
      factory,
      router,
      crss,
      wbnb,
      xCrss,
      mockTransfer,
    };
  });

  let factory: CrossFactory,
    router: CrossRouter,
    crss: CrssToken,
    wbnb: WBNBT,
    xCrss: XCrssToken,
    mockTransfer: MockTransfer;

  beforeEach("load fixture loader", async () => {
    ({ factory, router, crss, wbnb } = await setupTest());
  });

  it("feeTo, feeToSetter, allPairsLength", async () => {
    expect(await factory.feeTo()).to.eq(ethers.constants.AddressZero);
    expect(await factory.feeToSetter()).to.eq(owner.address);
    expect(await factory.allPairsLength()).to.eq(0);
  });

  async function createPair(tokens: [string, string]) {
    const bytecode = CrossPairAbi.bytecode;
    const create2Address = getCreate2Address(factory.address, tokens, bytecode);
    await expect(factory.createPair(...tokens))
      .to.emit(factory, "PairCreated")
      .withArgs(TEST_ADDRESSES[0], TEST_ADDRESSES[1], create2Address, BigNumber.from(1));
    await expect(factory.createPair(...tokens)).to.be.reverted; // Pancake: PAIR_EXISTS
    const reverseTokens = tokens.slice().reverse();
    await expect(factory.createPair(reverseTokens[0], reverseTokens[1])).to.be.reverted; // Pancake: PAIR_EXISTS
    expect(await factory.getPair(...tokens)).to.eq(create2Address);
    expect(await factory.getPair(reverseTokens[0], reverseTokens[1])).to.eq(create2Address);
    expect(await factory.allPairs(0)).to.eq(create2Address);
    expect(await factory.allPairsLength()).to.eq(1);

    const pair = (await ethers.getContractAt(CrossPairAbi.abi, create2Address, owner)) as CrossPair;
    expect(await pair.factory()).to.eq(factory.address);
    expect(await pair.token0()).to.eq(TEST_ADDRESSES[0]);
    expect(await pair.token1()).to.eq(TEST_ADDRESSES[1]);
  }

  it("createPair", async () => {
    await createPair(TEST_ADDRESSES);
  });

  it("createPair:reverse", async () => {
    await createPair(TEST_ADDRESSES.slice().reverse() as [string, string]);
  });

  it("createPair:gas", async () => {
    const tx = await factory.createPair(...TEST_ADDRESSES);
    const receipt = await tx.wait();
    expect(receipt.gasUsed).to.eq(2146902);
  });

  it("setFeeTo", async () => {
    await expect(factory.connect(userA).setFeeTo(userA.address)).to.be.revertedWith("Cross: FORBIDDEN");
    await factory.setFeeTo(owner.address);
    expect(await factory.feeTo()).to.eq(owner.address);
  });

  it("setFeeToSetter", async () => {
    await expect(factory.connect(userA).setFeeToSetter(userA.address)).to.be.revertedWith("Cross: FORBIDDEN");
    await factory.connect(owner).setFeeToSetter(userA.address);
    expect(await factory.feeToSetter()).to.eq(userA.address);
    await expect(factory.connect(owner).setFeeToSetter(userA.address)).to.be.revertedWith("Cross: FORBIDDEN");
  });
});

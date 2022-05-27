import { expect } from "chai";
import { BigNumber } from "ethers";
import hre, { deployments, ethers, waffle } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { ecsign } from "ethereumjs-util";

import { CrossFactory } from "../types/CrossFactory";
import { CrossRouter } from "../types/CrossRouter";
import { CrssToken } from "../types/CrssToken";
import { WBNB as WBNBT } from "../types/WBNB";
import { MockTransfer } from "../types/MockTransfer";
import { XCrssToken } from "../types/XCrssToken";
import { MockToken } from "../types/MockToken";
import { CrossPair } from "../types/CrossPair";

import CrossPairAbi from "../artifacts/contracts/core/CrossPair.sol/CrossPair.json";
import { expandTo18Decimals, getApprovalDigest, mineBlock } from "./shared/utilities";

export const MINIMUM_LIQUIDITY = BigNumber.from(10).pow(3);

const overrides = {
  gasLimit: 9999999,
};

describe("CrssRouter test", async () => {
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
    mockTransfer: MockTransfer,
    tokenA: MockToken,
    tokenB: MockToken,
    pair: CrossPair,
    token0: MockToken,
    token1: MockToken,
    wbnbPartner: MockToken,
    wbnbPair: CrossPair;
  const burnAddress = "0x000000000000000000000000000000000000dEaD";

  beforeEach("load fixture loader", async () => {
    ({ factory, router, crss, wbnb } = await setupTest());

    // console.log("owner is creating MockToken for tokenA and tokenB");
    const MockToken = await hre.ethers.getContractFactory("MockToken");
    tokenA = (await MockToken.deploy("tokenA", "tokenA")) as MockToken;
    tokenB = (await MockToken.deploy("tokenB", "tokenB")) as MockToken;

    // console.log("factory is creating pair of tokenA and tokenB");
    // create pair in factory
    await factory.createPair(tokenA.address, tokenB.address);
    const pairAddress = await factory.getPair(tokenA.address, tokenB.address);
    pair = (await hre.ethers.getContractAt(CrossPairAbi.abi, pairAddress, owner)) as CrossPair;

    const token0Address = await pair.token0();
    token0 = tokenA.address === token0Address ? tokenA : tokenB;
    token1 = tokenA.address === token0Address ? tokenB : tokenA;

    // console.log("factory is creating pair of wbnb and wbnbPair");
    wbnbPartner = (await MockToken.deploy("WBNBPartner", "WBNBPartner")) as MockToken;
    await factory.createPair(wbnb.address, wbnbPartner.address);
    const wbnbPairAddress = await factory.getPair(wbnb.address, wbnbPartner.address);
    wbnbPair = (await hre.ethers.getContractAt(CrossPairAbi.abi, wbnbPairAddress, owner)) as CrossPair;

    // console.log("owner is setting farm address with owner address");
    await crss.connect(owner).setFarm(owner.address);

    // // console.log("owner is minting crss to owner");
    // await crss.connect(owner).mint(owner.address, ethers.utils.parseEther("100000"));
    // // console.log("owner is minting tokenA to owner");
    // await tokenA.connect(owner).mint(owner.address, ethers.utils.parseEther("100000"));
    // // console.log("owner is minting tokenB to owner");
    // await tokenB.connect(owner).mint(owner.address, ethers.utils.parseEther("100000"));
    // // console.log("owner is minting wbnbPartner to owner");
    // await wbnbPartner.connect(owner).mint(owner.address, ethers.utils.parseEther("100000"));
  });

  afterEach(async function () {
    expect(await waffle.provider.getBalance(router.address)).to.be.equal("0");
  });

  it("factory, WBNB", async function () {
    expect(await router.factory()).to.be.equal(factory.address);
    expect(await router.WETH()).to.be.equal(wbnb.address);
  });

  it("addLiquidity", async function () {
    const token0Amount = expandTo18Decimals(1);
    const token1Amount = expandTo18Decimals(4);

    await token0.connect(owner).mint(owner.address, token0Amount);
    await token1.connect(owner).mint(owner.address, token1Amount);

    const expectedLiquidity = expandTo18Decimals(2);
    await token0.connect(owner).approve(router.address, ethers.constants.MaxInt256);
    await token1.connect(owner).approve(router.address, ethers.constants.MaxInt256);
    await expect(
      router.addLiquidity(
        token0.address,
        token1.address,
        token0Amount,
        token1Amount,
        0,
        0,
        owner.address,
        ethers.constants.MaxInt256,
        overrides
      )
    )
      .to.emit(token0, "Transfer")
      .withArgs(owner.address, pair.address, token0Amount)
      .to.emit(token1, "Transfer")
      .withArgs(owner.address, pair.address, token1Amount)
      .to.emit(pair, "Transfer")
      .withArgs(ethers.constants.AddressZero, ethers.constants.AddressZero, MINIMUM_LIQUIDITY)
      .to.emit(pair, "Transfer")
      .withArgs(ethers.constants.AddressZero, owner.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
      .to.emit(pair, "Sync")
      .withArgs(token0Amount, token1Amount)
      .to.emit(pair, "Mint")
      .withArgs(router.address, token0Amount, token1Amount);

    expect(await pair.balanceOf(owner.address)).to.eq(expectedLiquidity.sub(MINIMUM_LIQUIDITY));
  });

  it("addLiquidityETH", async () => {
    const WETHPartnerAmount = expandTo18Decimals(1);
    const ETHAmount = expandTo18Decimals(4);

    await wbnbPartner.connect(owner).mint(owner.address, WETHPartnerAmount);

    const expectedLiquidity = expandTo18Decimals(2);
    const WETHPairToken0 = await wbnbPair.token0();
    await wbnbPartner.approve(router.address, ethers.constants.MaxUint256);
    await expect(
      router.addLiquidityETH(
        wbnbPartner.address,
        WETHPartnerAmount,
        WETHPartnerAmount,
        ETHAmount,
        owner.address,
        ethers.constants.MaxUint256,
        {
          ...overrides,
          value: ETHAmount,
        }
      )
    )
      .to.emit(wbnbPair, "Transfer")
      .withArgs(ethers.constants.AddressZero, ethers.constants.AddressZero, MINIMUM_LIQUIDITY)
      .to.emit(wbnbPair, "Transfer")
      .withArgs(ethers.constants.AddressZero, owner.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
      .to.emit(wbnbPair, "Sync")
      .withArgs(
        WETHPairToken0 === wbnbPartner.address ? WETHPartnerAmount : ETHAmount,
        WETHPairToken0 === wbnbPartner.address ? ETHAmount : WETHPartnerAmount
      )
      .to.emit(wbnbPair, "Mint")
      .withArgs(
        router.address,
        WETHPairToken0 === wbnbPartner.address ? WETHPartnerAmount : ETHAmount,
        WETHPairToken0 === wbnbPartner.address ? ETHAmount : WETHPartnerAmount
      );

    expect(await wbnbPair.balanceOf(owner.address)).to.eq(expectedLiquidity.sub(MINIMUM_LIQUIDITY));
  });

  async function addLiquidity(token0Amount: BigNumber, token1Amount: BigNumber) {
    await token0.connect(owner).mint(owner.address, token0Amount);
    await token1.connect(owner).mint(owner.address, token1Amount);

    await token0.transfer(pair.address, token0Amount);
    await token1.transfer(pair.address, token1Amount);
    await pair.mint(owner.address, overrides);
  }

  it("removeLiquidity", async () => {
    const token0Amount = expandTo18Decimals(1);
    const token1Amount = expandTo18Decimals(4);
    await addLiquidity(token0Amount, token1Amount);

    const expectedLiquidity = expandTo18Decimals(2);
    await pair.approve(router.address, ethers.constants.MaxUint256);
    await expect(
      router.removeLiquidity(
        token0.address,
        token1.address,
        expectedLiquidity.sub(MINIMUM_LIQUIDITY),
        0,
        0,
        owner.address,
        ethers.constants.MaxUint256,
        overrides
      )
    )
      .to.emit(pair, "Transfer")
      .withArgs(owner.address, pair.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
      .to.emit(pair, "Transfer")
      .withArgs(pair.address, ethers.constants.AddressZero, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
      .to.emit(token0, "Transfer")
      .withArgs(pair.address, owner.address, token0Amount.sub(500))
      .to.emit(token1, "Transfer")
      .withArgs(pair.address, owner.address, token1Amount.sub(2000))
      .to.emit(pair, "Sync")
      .withArgs(500, 2000)
      .to.emit(pair, "Burn")
      .withArgs(router.address, token0Amount.sub(500), token1Amount.sub(2000), owner.address);

    expect(await pair.balanceOf(owner.address)).to.eq(0);
    const totalSupplyToken0 = await token0.totalSupply();
    const totalSupplyToken1 = await token1.totalSupply();
    expect(await token0.balanceOf(owner.address)).to.eq(totalSupplyToken0.sub(500));
    expect(await token1.balanceOf(owner.address)).to.eq(totalSupplyToken1.sub(2000));
  });

  it("removeLiquidityETH", async () => {
    const WETHPartnerAmount = expandTo18Decimals(1);
    const ETHAmount = expandTo18Decimals(4);

    await wbnbPartner.connect(owner).mint(owner.address, WETHPartnerAmount);
    await wbnbPartner.transfer(wbnbPair.address, WETHPartnerAmount);
    await wbnb.deposit({ value: ETHAmount });
    await wbnb.transfer(wbnbPair.address, ETHAmount);
    await wbnbPair.mint(owner.address, overrides);

    const expectedLiquidity = expandTo18Decimals(2);
    const WETHPairToken0 = await wbnbPair.token0();
    await wbnbPair.approve(router.address, ethers.constants.MaxUint256);
    await expect(
      router.removeLiquidityETH(
        wbnbPartner.address,
        expectedLiquidity.sub(MINIMUM_LIQUIDITY),
        0,
        0,
        owner.address,
        ethers.constants.MaxUint256,
        overrides
      )
    )
      .to.emit(wbnbPair, "Transfer")
      .withArgs(owner.address, wbnbPair.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
      .to.emit(wbnbPair, "Transfer")
      .withArgs(wbnbPair.address, ethers.constants.AddressZero, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
      .to.emit(wbnb, "Transfer")
      .withArgs(wbnbPair.address, router.address, ETHAmount.sub(2000))
      .to.emit(wbnbPartner, "Transfer")
      .withArgs(wbnbPair.address, router.address, WETHPartnerAmount.sub(500))
      .to.emit(wbnbPartner, "Transfer")
      .withArgs(router.address, owner.address, WETHPartnerAmount.sub(500))
      .to.emit(wbnbPair, "Sync")
      .withArgs(
        WETHPairToken0 === wbnbPartner.address ? 500 : 2000,
        WETHPairToken0 === wbnbPartner.address ? 2000 : 500
      )
      .to.emit(wbnbPair, "Burn")
      .withArgs(
        router.address,
        WETHPairToken0 === wbnbPartner.address ? WETHPartnerAmount.sub(500) : ETHAmount.sub(2000),
        WETHPairToken0 === wbnbPartner.address ? ETHAmount.sub(2000) : WETHPartnerAmount.sub(500),
        router.address
      );

    expect(await wbnbPair.balanceOf(owner.address)).to.eq(0);
    const totalSupplyWETHPartner = await wbnbPartner.totalSupply();
    const totalSupplyWETH = await wbnb.totalSupply();
    expect(await wbnbPartner.balanceOf(owner.address)).to.eq(totalSupplyWETHPartner.sub(500));
    expect(await wbnb.balanceOf(owner.address)).to.eq(totalSupplyWETH.sub(2000));
  });

  it("removeLiquidityWithPermit", async () => {
    const token0Amount = expandTo18Decimals(1);
    const token1Amount = expandTo18Decimals(4);
    await addLiquidity(token0Amount, token1Amount);

    const expectedLiquidity = expandTo18Decimals(2);

    const nonce = await pair.nonces(owner.address);
    const digest = await getApprovalDigest(
      pair,
      {
        owner: owner.address,
        spender: router.address,
        value: expectedLiquidity.sub(MINIMUM_LIQUIDITY),
      },
      nonce,
      ethers.constants.MaxUint256
    );

    const { v, r, s } = ecsign(Buffer.from(digest.slice(2), "hex"), Buffer.from(owner.privateKey.slice(2), "hex"));

    await router.removeLiquidityWithPermit(
      token0.address,
      token1.address,
      expectedLiquidity.sub(MINIMUM_LIQUIDITY),
      0,
      0,
      owner.address,
      ethers.constants.MaxUint256,
      false,
      v,
      r,
      s,
      overrides
    );
  });

  it("removeLiquidityETHWithPermit", async () => {
    const WETHPartnerAmount = expandTo18Decimals(1);
    const ETHAmount = expandTo18Decimals(4);

    await wbnbPartner.connect(owner).mint(owner.address, WETHPartnerAmount);
    await wbnbPartner.transfer(wbnbPair.address, WETHPartnerAmount);
    await wbnb.deposit({ value: ETHAmount });
    await wbnb.transfer(wbnbPair.address, ETHAmount);
    await wbnbPair.mint(owner.address, overrides);

    const expectedLiquidity = expandTo18Decimals(2);

    const nonce = await wbnbPair.nonces(owner.address);
    const digest = await getApprovalDigest(
      wbnbPair,
      {
        owner: owner.address,
        spender: router.address,
        value: expectedLiquidity.sub(MINIMUM_LIQUIDITY),
      },
      nonce,
      ethers.constants.MaxUint256
    );

    const { v, r, s } = ecsign(Buffer.from(digest.slice(2), "hex"), Buffer.from(owner.privateKey.slice(2), "hex"));

    await router.removeLiquidityETHWithPermit(
      wbnbPartner.address,
      expectedLiquidity.sub(MINIMUM_LIQUIDITY),
      0,
      0,
      owner.address,
      ethers.constants.MaxUint256,
      false,
      v,
      r,
      s,
      overrides
    );
  });

  describe("swapExactTokensForTokens", () => {
    const token0Amount = expandTo18Decimals(5);
    const token1Amount = expandTo18Decimals(10);
    const swapAmount = expandTo18Decimals(1);
    const expectedOutputAmount = BigNumber.from("1663887962654218072");

    beforeEach(async () => {
      await addLiquidity(token0Amount, token1Amount);
      await token0.approve(router.address, ethers.constants.MaxUint256);
    });

    it("happy path", async () => {
      await token0.connect(owner).mint(owner.address, swapAmount);

      await expect(
        router.swapExactTokensForTokens(
          swapAmount,
          0,
          [token0.address, token1.address],
          owner.address,
          ethers.constants.MaxUint256,
          overrides
        )
      )
        .to.emit(token0, "Transfer")
        .withArgs(owner.address, pair.address, swapAmount)
        .to.emit(token1, "Transfer")
        .withArgs(pair.address, owner.address, expectedOutputAmount)
        .to.emit(pair, "Sync")
        .withArgs(token0Amount.add(swapAmount), token1Amount.sub(expectedOutputAmount))
        .to.emit(pair, "Swap")
        .withArgs(router.address, swapAmount, 0, 0, expectedOutputAmount, owner.address);
    });

    // it('amounts', async () => {
    //   await token0.approve(routerEventEmitter.address, ethers.constants.MaxUint256)
    //   await expect(
    //     routerEventEmitter.swapExactTokensForTokens(
    //       router.address,
    //       swapAmount,
    //       0,
    //       [token0.address, token1.address],
    //       owner.address,
    //       ethers.constants.MaxUint256,
    //       overrides
    //     )
    //   )
    //     .to.emit(routerEventEmitter, 'Amounts')
    //     .withArgs([swapAmount, expectedOutputAmount])
    // })

    it("gas", async () => {
      // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
      await mineBlock((await waffle.provider.getBlock("latest")).timestamp + 1);
      await pair.sync(overrides);

      await token0.approve(router.address, ethers.constants.MaxUint256);
      await mineBlock((await waffle.provider.getBlock("latest")).timestamp + 1);

      await token0.connect(owner).mint(owner.address, swapAmount);

      const tx = await router.swapExactTokensForTokens(
        swapAmount,
        0,
        [token0.address, token1.address],
        owner.address,
        ethers.constants.MaxUint256,
        overrides
      );
      const receipt = await tx.wait();
      expect(receipt.gasUsed).to.eq(126033);
    }).retries(3);

    // @todo, not sure why swapTransfersInOneTx returns empty any time
    // it("should accumulate the swap amount per user", async function () {
    //   await token0.connect(owner).mint(owner.address, swapAmount);

    //   await router.swapExactTokensForTokens(
    //     swapAmount,
    //     0,
    //     [token0.address, token1.address],
    //     owner.address,
    //     ethers.constants.MaxUint256,
    //     overrides
    //   );

    //   expect((await crss.swapTransfersInOneTx(token0.address)).sent).to.be.equal(swapAmount);
    //   expect((await crss.swapTransfersInOneTx(token1.address)).sent).to.be.equal(expectedOutputAmount);
    // });

    it("whitelisted address should allow to swap large amount", async function () {
      // @todo
    });

    // it("accumulated swap amount should not affect on another swapping", async function () {
    //   await token0.connect(owner).mint(owner.address, swapAmount);

    //   await router.swapExactTokensForTokens(
    //     swapAmount,
    //     0,
    //     [token0.address, token1.address],
    //     owner.address,
    //     ethers.constants.MaxUint256,
    //     overrides
    //   );
    //   // todo
    // });

    // it("should revert if exceed the max swap amount", async function () {
    //   await token0.connect(owner).mint(owner.address, expandTo18Decimals(3));

    //   await expect(
    //     router.swapExactTokensForTokens(
    //       expandTo18Decimals(3),
    //       0,
    //       [token0.address, token1.address],
    //       owner.address,
    //       ethers.constants.MaxUint256,
    //       overrides
    //     )
    //   ).to.revertedWith("Cross: Exceed Swap Amount");
    // });
  });

  describe("swapTokensForExactTokens", () => {
    const token0Amount = expandTo18Decimals(5);
    const token1Amount = expandTo18Decimals(10);
    const expectedSwapAmount = BigNumber.from("556668893342240036");
    const outputAmount = expandTo18Decimals(1);

    beforeEach(async () => {
      await addLiquidity(token0Amount, token1Amount);
    });

    it("happy path", async () => {
      await token0.connect(owner).mint(owner.address, outputAmount);

      await token0.approve(router.address, ethers.constants.MaxUint256);
      await expect(
        router.swapTokensForExactTokens(
          outputAmount,
          ethers.constants.MaxUint256,
          [token0.address, token1.address],
          owner.address,
          ethers.constants.MaxUint256,
          overrides
        )
      )
        .to.emit(token0, "Transfer")
        .withArgs(owner.address, pair.address, expectedSwapAmount)
        .to.emit(token1, "Transfer")
        .withArgs(pair.address, owner.address, outputAmount)
        .to.emit(pair, "Sync")
        .withArgs(token0Amount.add(expectedSwapAmount), token1Amount.sub(outputAmount))
        .to.emit(pair, "Swap")
        .withArgs(router.address, expectedSwapAmount, 0, 0, outputAmount, owner.address);
    });

    // it('amounts', async () => {
    //   await token0.approve(routerEventEmitter.address, ethers.constants.MaxUint256)
    //   await expect(
    //     routerEventEmitter.swapTokensForExactTokens(
    //       router.address,
    //       outputAmount,
    //       ethers.constants.MaxUint256,
    //       [token0.address, token1.address],
    //       owner.address,
    //       ethers.constants.MaxUint256,
    //       overrides
    //     )
    //   )
    //     .to.emit(routerEventEmitter, 'Amounts')
    //     .withArgs([expectedSwapAmount, outputAmount])
    // })

    // it("should accumulate the swap amount per user", async function () {
    //   await token0.connect(owner).mint(owner.address, expectedSwapAmount);

    //   await router.swapTokensForExactTokens(
    //     expectedSwapAmount,
    //     0,
    //     [token0.address, token1.address],
    //     owner.address,
    //     ethers.constants.MaxUint256,
    //     overrides
    //   );

    //   expect((await crss.swapTransfersInOneTx(token0.address)).sent).to.be.equal(expectedSwapAmount);
    //   expect((await crss.swapTransfersInOneTx(token1.address)).sent).to.be.equal(outputAmount);
    // });

    it("whitelisted address should allow to swap large amount", async function () {
      // @todo
    });

    // it("accumulated swap amount should not affect on another swapping", async function () {
    //   await token0.connect(owner).mint(owner.address, expectedSwapAmount);

    //   await router.swapTokensForExactTokens(
    //     expectedSwapAmount,
    //     0,
    //     [token0.address, token1.address],
    //     owner.address,
    //     ethers.constants.MaxUint256,
    //     overrides
    //   );
    //   // @todo
    // });

    // it("should revert if exceed the max swap amount", async function () {
    //   await token0.connect(owner).mint(owner.address, expandTo18Decimals(3));

    //   await expect(
    //     router.swapTokensForExactTokens(
    //       expandTo18Decimals(3),
    //       0,
    //       [token0.address, token1.address],
    //       owner.address,
    //       ethers.constants.MaxUint256,
    //       overrides
    //     )
    //   ).to.revertedWith("Cross: Exceed Swap Amount");
    // });
  });

  describe("swapExactETHForTokens", () => {
    const WETHPartnerAmount = expandTo18Decimals(10);
    const ETHAmount = expandTo18Decimals(5);
    const swapAmount = expandTo18Decimals(1);
    const expectedOutputAmount = BigNumber.from("1663887962654218072");

    beforeEach(async () => {
      await wbnbPartner.connect(owner).mint(owner.address, WETHPartnerAmount);
      await wbnbPartner.transfer(wbnbPair.address, WETHPartnerAmount);
      await wbnb.deposit({ value: ETHAmount });
      await wbnb.transfer(wbnbPair.address, ETHAmount);
      await wbnbPair.mint(owner.address, overrides);

      await token0.approve(router.address, ethers.constants.MaxUint256);
    });

    it("happy path", async () => {
      const WETHPairToken0 = await wbnbPair.token0();
      await expect(
        router.swapExactETHForTokens(
          0,
          [wbnb.address, wbnbPartner.address],
          owner.address,
          ethers.constants.MaxUint256,
          {
            ...overrides,
            value: swapAmount,
          }
        )
      )
        .to.emit(wbnb, "Transfer")
        .withArgs(router.address, wbnbPair.address, swapAmount)
        .to.emit(wbnbPartner, "Transfer")
        .withArgs(wbnbPair.address, owner.address, expectedOutputAmount)
        .to.emit(wbnbPair, "Sync")
        .withArgs(
          WETHPairToken0 === wbnbPartner.address
            ? WETHPartnerAmount.sub(expectedOutputAmount)
            : ETHAmount.add(swapAmount),
          WETHPairToken0 === wbnbPartner.address
            ? ETHAmount.add(swapAmount)
            : WETHPartnerAmount.sub(expectedOutputAmount)
        )
        .to.emit(wbnbPair, "Swap")
        .withArgs(
          router.address,
          WETHPairToken0 === wbnbPartner.address ? 0 : swapAmount,
          WETHPairToken0 === wbnbPartner.address ? swapAmount : 0,
          WETHPairToken0 === wbnbPartner.address ? expectedOutputAmount : 0,
          WETHPairToken0 === wbnbPartner.address ? 0 : expectedOutputAmount,
          owner.address
        );
    });

    // it('amounts', async () => {
    //   await expect(
    //     routerEventEmitter.swapExactETHForTokens(
    //       router.address,
    //       0,
    //       [wbnb.address, wbnbPartner.address],
    //       owner.address,
    //       ethers.constants.MaxUint256,
    //       {
    //         ...overrides,
    //         value: swapAmount
    //       }
    //     )
    //   )
    //     .to.emit(routerEventEmitter, 'Amounts')
    //     .withArgs([swapAmount, expectedOutputAmount])
    // })

    it("gas", async () => {
      const WETHPartnerAmount = expandTo18Decimals(10);
      const ETHAmount = expandTo18Decimals(5);
      await wbnbPartner.connect(owner).mint(owner.address, WETHPartnerAmount);
      await wbnbPartner.transfer(wbnbPair.address, WETHPartnerAmount);
      await wbnb.deposit({ value: ETHAmount });
      await wbnb.transfer(wbnbPair.address, ETHAmount);
      await wbnbPair.mint(owner.address, overrides);

      // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
      await mineBlock((await waffle.provider.getBlock("latest")).timestamp + 1);
      await pair.sync(overrides);

      const swapAmount = expandTo18Decimals(1);
      await mineBlock((await waffle.provider.getBlock("latest")).timestamp + 1);
      const tx = await router.swapExactETHForTokens(
        0,
        [wbnb.address, wbnbPartner.address],
        owner.address,
        ethers.constants.MaxUint256,
        {
          ...overrides,
          value: swapAmount,
        }
      );
      const receipt = await tx.wait();
      expect(receipt.gasUsed).to.eq(129163);
    }).retries(3);

    // it("should accumulate the swap amount per user", async function () {
    //   await router.swapExactETHForTokens(
    //     0,
    //     [wbnb.address, wbnbPartner.address],
    //     owner.address,
    //     ethers.constants.MaxUint256,
    //     {
    //       ...overrides,
    //       value: swapAmount,
    //     }
    //   );

    //   expect((await crss.swapTransfersInOneTx(wbnb.address)).sent).to.be.equal(swapAmount);
    //   expect((await crss.swapTransfersInOneTx(wbnbPartner.address)).sent).to.be.equal(expectedOutputAmount);
    // });

    it("whitelisted address should allow to swap large amount", async function () {
      // @todo
    });

    // it("accumulated swap amount should not affect on another swapping", async function () {
    //   await router.swapExactETHForTokens(
    //     0,
    //     [wbnb.address, wbnbPartner.address],
    //     owner.address,
    //     ethers.constants.MaxUint256,
    //     {
    //       ...overrides,
    //       value: swapAmount,
    //     }
    //   );
    //   // todo
    // });

    // it("should revert if exceed the max swap amount", async function () {
    //   await expect(
    //     router.swapExactETHForTokens(
    //       0,
    //       [wbnb.address, wbnbPartner.address],
    //       owner.address,
    //       ethers.constants.MaxUint256,
    //       {
    //         ...overrides,
    //         value: expandTo18Decimals(3),
    //       }
    //     )
    //   ).to.revertedWith("Cross: Exceed Swap Amount");
    // });
  });

  describe("swapTokensForExactETH", () => {
    const WETHPartnerAmount = expandTo18Decimals(5);
    const ETHAmount = expandTo18Decimals(10);
    const expectedSwapAmount = BigNumber.from("556668893342240036");
    const outputAmount = expandTo18Decimals(1);

    beforeEach(async () => {
      await wbnbPartner.connect(owner).mint(owner.address, WETHPartnerAmount);
      await wbnbPartner.transfer(wbnbPair.address, WETHPartnerAmount);
      await wbnb.deposit({ value: ETHAmount });
      await wbnb.transfer(wbnbPair.address, ETHAmount);
      await wbnbPair.mint(owner.address, overrides);
    });

    it("happy path", async () => {
      await wbnbPartner.connect(owner).mint(owner.address, outputAmount);
      await wbnbPartner.approve(router.address, ethers.constants.MaxUint256);
      const WETHPairToken0 = await wbnbPair.token0();
      await expect(
        router.swapTokensForExactETH(
          outputAmount,
          ethers.constants.MaxUint256,
          [wbnbPartner.address, wbnb.address],
          owner.address,
          ethers.constants.MaxUint256,
          overrides
        )
      )
        .to.emit(wbnbPartner, "Transfer")
        .withArgs(owner.address, wbnbPair.address, expectedSwapAmount)
        .to.emit(wbnb, "Transfer")
        .withArgs(wbnbPair.address, router.address, outputAmount)
        .to.emit(wbnbPair, "Sync")
        .withArgs(
          WETHPairToken0 === wbnbPartner.address
            ? WETHPartnerAmount.add(expectedSwapAmount)
            : ETHAmount.sub(outputAmount),
          WETHPairToken0 === wbnbPartner.address
            ? ETHAmount.sub(outputAmount)
            : WETHPartnerAmount.add(expectedSwapAmount)
        )
        .to.emit(wbnbPair, "Swap")
        .withArgs(
          router.address,
          WETHPairToken0 === wbnbPartner.address ? expectedSwapAmount : 0,
          WETHPairToken0 === wbnbPartner.address ? 0 : expectedSwapAmount,
          WETHPairToken0 === wbnbPartner.address ? 0 : outputAmount,
          WETHPairToken0 === wbnbPartner.address ? outputAmount : 0,
          router.address
        );
    });

    // it('amounts', async () => {
    //   await wbnbPartner.approve(routerEventEmitter.address, ethers.constants.MaxUint256)
    //   await expect(
    //     routerEventEmitter.swapTokensForExactETH(
    //       router.address,
    //       outputAmount,
    //       ethers.constants.MaxUint256,
    //       [wbnbPartner.address, wbnb.address],
    //       owner.address,
    //       ethers.constants.MaxUint256,
    //       overrides
    //     )
    //   )
    //     .to.emit(routerEventEmitter, 'Amounts')
    //     .withArgs([expectedSwapAmount, outputAmount])
    // })

    // it("should accumulate the swap amount per user", async function () {
    //   await wbnbPartner.connect(owner).mint(owner.address, outputAmount);
    //   await router.swapTokensForExactETH(
    //     outputAmount,
    //     ethers.constants.MaxUint256,
    //     [wbnbPartner.address, wbnb.address],
    //     owner.address,
    //     ethers.constants.MaxUint256,
    //     overrides
    //   );

    //   expect((await crss.swapTransfersInOneTx(wbnbPartner.address)).sent).to.be.equal(expectedSwapAmount);
    //   expect((await crss.swapTransfersInOneTx(wbnb.address)).sent).to.be.equal(outputAmount);
    // });

    it("whitelisted address should allow to swap large amount", async function () {
      // @todo
    });

    // it("accumulated swap amount should not affect on another swapping", async function () {
    //   await wbnbPartner.connect(owner).mint(owner.address, outputAmount);
    //   await router.swapTokensForExactETH(
    //     outputAmount,
    //     ethers.constants.MaxUint256,
    //     [wbnbPartner.address, wbnb.address],
    //     owner.address,
    //     ethers.constants.MaxUint256,
    //     overrides
    //   );
    //   // todo
    // });

    // it("should revert if exceed the max swap amount", async function () {
    //   await wbnbPartner.connect(owner).mint(owner.address, expandTo18Decimals(3));
    //   await expect(
    //     router.swapTokensForExactETH(
    //       expandTo18Decimals(3),
    //       ethers.constants.MaxUint256,
    //       [wbnbPartner.address, wbnb.address],
    //       owner.address,
    //       ethers.constants.MaxUint256,
    //       overrides
    //     )
    //   ).to.revertedWith("Cross: Exceed Swap Amount");
    // });
  });

  describe("swapExactTokensForETH", () => {
    const WETHPartnerAmount = expandTo18Decimals(5);
    const ETHAmount = expandTo18Decimals(10);
    const swapAmount = expandTo18Decimals(1);
    const expectedOutputAmount = BigNumber.from("1663887962654218072");

    beforeEach(async () => {
      await wbnbPartner.connect(owner).mint(owner.address, WETHPartnerAmount);
      await wbnbPartner.transfer(wbnbPair.address, WETHPartnerAmount);
      await wbnb.deposit({ value: ETHAmount });
      await wbnb.transfer(wbnbPair.address, ETHAmount);
      await wbnbPair.mint(owner.address, overrides);
    });

    it("happy path", async () => {
      await wbnbPartner.connect(owner).mint(owner.address, swapAmount);
      await wbnbPartner.approve(router.address, ethers.constants.MaxUint256);
      const WETHPairToken0 = await wbnbPair.token0();
      await expect(
        router.swapExactTokensForETH(
          swapAmount,
          0,
          [wbnbPartner.address, wbnb.address],
          owner.address,
          ethers.constants.MaxUint256,
          overrides
        )
      )
        .to.emit(wbnbPartner, "Transfer")
        .withArgs(owner.address, wbnbPair.address, swapAmount)
        .to.emit(wbnb, "Transfer")
        .withArgs(wbnbPair.address, router.address, expectedOutputAmount)
        .to.emit(wbnbPair, "Sync")
        .withArgs(
          WETHPairToken0 === wbnbPartner.address
            ? WETHPartnerAmount.add(swapAmount)
            : ETHAmount.sub(expectedOutputAmount),
          WETHPairToken0 === wbnbPartner.address
            ? ETHAmount.sub(expectedOutputAmount)
            : WETHPartnerAmount.add(swapAmount)
        )
        .to.emit(wbnbPair, "Swap")
        .withArgs(
          router.address,
          WETHPairToken0 === wbnbPartner.address ? swapAmount : 0,
          WETHPairToken0 === wbnbPartner.address ? 0 : swapAmount,
          WETHPairToken0 === wbnbPartner.address ? 0 : expectedOutputAmount,
          WETHPairToken0 === wbnbPartner.address ? expectedOutputAmount : 0,
          router.address
        );
    });

    // it('amounts', async () => {
    //   await wbnbPartner.approve(routerEventEmitter.address, ethers.constants.MaxUint256)
    //   await expect(
    //     routerEventEmitter.swapExactTokensForETH(
    //       router.address,
    //       swapAmount,
    //       0,
    //       [wbnbPartner.address, wbnb.address],
    //       owner.address,
    //       ethers.constants.MaxUint256,
    //       overrides
    //     )
    //   )
    //     .to.emit(routerEventEmitter, 'Amounts')
    //     .withArgs([swapAmount, expectedOutputAmount])
    // })

    // it("should accumulate the swap amount per user", async function () {
    //   await wbnbPartner.connect(owner).mint(owner.address, swapAmount);
    //   await router.swapExactTokensForETH(
    //     swapAmount,
    //     0,
    //     [wbnbPartner.address, wbnb.address],
    //     owner.address,
    //     ethers.constants.MaxUint256,
    //     overrides
    //   );

    //   expect((await crss.swapTransfersInOneTx(wbnbPartner.address)).sent).to.be.equal(swapAmount);
    //   expect((await crss.swapTransfersInOneTx(wbnb.address)).sent).to.be.equal(expectedOutputAmount);
    // });

    it("whitelisted address should allow to swap large amount", async function () {
      // todo
    });

    // it("accumulated swap amount should not affect on another swapping", async function () {
    //   await wbnbPartner.connect(owner).mint(owner.address, swapAmount);
    //   await router.swapExactTokensForETH(
    //     swapAmount,
    //     0,
    //     [wbnbPartner.address, wbnb.address],
    //     owner.address,
    //     ethers.constants.MaxUint256,
    //     overrides
    //   );
    //   // todo
    // });

    // it("should revert if exceed the max swap amount", async function () {
    //   await wbnbPartner.connect(owner).mint(owner.address, expandTo18Decimals(3));
    //   await expect(
    //     router.swapExactTokensForETH(
    //       expandTo18Decimals(3),
    //       0,
    //       [wbnbPartner.address, wbnb.address],
    //       owner.address,
    //       ethers.constants.MaxUint256,
    //       overrides
    //     )
    //   ).to.revertedWith("Cross: Exceed Swap Amount");
    // });
  });

  describe("swapETHForExactTokens", () => {
    const WETHPartnerAmount = expandTo18Decimals(10);
    const ETHAmount = expandTo18Decimals(5);
    const expectedSwapAmount = BigNumber.from("556668893342240036");
    const outputAmount = expandTo18Decimals(1);

    beforeEach(async () => {
      await wbnbPartner.connect(owner).mint(owner.address, WETHPartnerAmount);
      await wbnbPartner.transfer(wbnbPair.address, WETHPartnerAmount);
      await wbnb.deposit({ value: ETHAmount });
      await wbnb.transfer(wbnbPair.address, ETHAmount);
      await wbnbPair.mint(owner.address, overrides);
    });

    it("happy path", async () => {
      const WETHPairToken0 = await wbnbPair.token0();
      await expect(
        router.swapETHForExactTokens(
          outputAmount,
          [wbnb.address, wbnbPartner.address],
          owner.address,
          ethers.constants.MaxUint256,
          {
            ...overrides,
            value: expectedSwapAmount,
          }
        )
      )
        .to.emit(wbnb, "Transfer")
        .withArgs(router.address, wbnbPair.address, expectedSwapAmount)
        .to.emit(wbnbPartner, "Transfer")
        .withArgs(wbnbPair.address, owner.address, outputAmount)
        .to.emit(wbnbPair, "Sync")
        .withArgs(
          WETHPairToken0 === wbnbPartner.address
            ? WETHPartnerAmount.sub(outputAmount)
            : ETHAmount.add(expectedSwapAmount),
          WETHPairToken0 === wbnbPartner.address
            ? ETHAmount.add(expectedSwapAmount)
            : WETHPartnerAmount.sub(outputAmount)
        )
        .to.emit(wbnbPair, "Swap")
        .withArgs(
          router.address,
          WETHPairToken0 === wbnbPartner.address ? 0 : expectedSwapAmount,
          WETHPairToken0 === wbnbPartner.address ? expectedSwapAmount : 0,
          WETHPairToken0 === wbnbPartner.address ? outputAmount : 0,
          WETHPairToken0 === wbnbPartner.address ? 0 : outputAmount,
          owner.address
        );
    });

    // it('amounts', async () => {
    //   await expect(
    //     routerEventEmitter.swapETHForExactTokens(
    //       router.address,
    //       outputAmount,
    //       [wbnb.address, wbnbPartner.address],
    //       owner.address,
    //       ethers.constants.MaxUint256,
    //       {
    //         ...overrides,
    //         value: expectedSwapAmount
    //       }
    //     )
    //   )
    //     .to.emit(routerEventEmitter, 'Amounts')
    //     .withArgs([expectedSwapAmount, outputAmount])
    // })

    // it("should accumulate the swap amount per user", async function () {
    //   await router.swapETHForExactTokens(
    //     outputAmount,
    //     [wbnb.address, wbnbPartner.address],
    //     owner.address,
    //     ethers.constants.MaxUint256,
    //     {
    //       ...overrides,
    //       value: expectedSwapAmount,
    //     }
    //   );

    //   expect((await crss.swapTransfersInOneTx(wbnb.address)).sent).to.be.equal(outputAmount);
    //   expect((await crss.swapTransfersInOneTx(wbnbPartner.address)).sent).to.be.equal(expectedSwapAmount);
    // });

    it("whitelisted address should allow to swap large amount", async function () {
      // @todo
    });

    // it("accumulated swap amount should not affect on another swapping", async function () {
    //   await router.swapETHForExactTokens(
    //     outputAmount,
    //     [wbnb.address, wbnbPartner.address],
    //     owner.address,
    //     ethers.constants.MaxUint256,
    //     {
    //       ...overrides,
    //       value: expectedSwapAmount,
    //     }
    //   );
    //   // todo
    // });

    // it("should revert if exceed the max swap amount", async function () {
    //   await expect(
    //     await router.swapETHForExactTokens(
    //       expandTo18Decimals(3),
    //       [wbnb.address, wbnbPartner.address],
    //       owner.address,
    //       ethers.constants.MaxUint256,
    //       {
    //         ...overrides,
    //         value: expectedSwapAmount,
    //       }
    //     )
    //   ).to.revertedWith("Cross: Exceed Swap Amount");
    // });
  });

  it("getAmountsOut", async () => {
    await token0.connect(owner).mint(owner.address, "10000");
    await token1.connect(owner).mint(owner.address, "10000");

    await token0.approve(router.address, ethers.constants.MaxUint256);
    await token1.approve(router.address, ethers.constants.MaxUint256);

    await router.addLiquidity(
      token0.address,
      token1.address,
      BigNumber.from(10000),
      BigNumber.from(10000),
      0,
      0,
      owner.address,
      ethers.constants.MaxUint256,
      overrides
    );

    await expect(router.getAmountsOut(BigNumber.from(2), [token0.address])).to.be.revertedWith(
      "CrossLibrary: INVALID_PATH"
    );
    const path = [token0.address, token1.address];
    expect(await router.getAmountsOut(BigNumber.from(2), path)).to.deep.eq([BigNumber.from(2), BigNumber.from(1)]);
  });
});

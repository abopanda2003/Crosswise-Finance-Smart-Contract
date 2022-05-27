const { ethers, waffle, network, upgrades } = require("hardhat");
const { expect } = require("chai");
//const { FakeContract, smock } = require("@defi-wonderland/smock");

const { utils } = require("ethers");
const { abi: pairAbi } = require("../artifacts/contracts/core/CrossPair.sol/CrossPair.json");

let factory, router, wbnb, crss, mock, crss_mockPair, crss_ethPair, devTo, buybackTo;

describe("Cross Comprehensive Test", async () => {
  /**
   * Everything in this block is only run once before all tests.
   * This is the home for setup methodss
   */

  before(async () => {
    [deployer, alice, bob, carol, david, evan] = await ethers.getSigners();
    devTo = david.address;
    buybackTo = evan.address;

    const Factory = await ethers.getContractFactory("CrossFactory");
    factory = await Factory.deploy(deployer.address);
    console.log("\nFactory Deployed: ", factory.address);

    const WBNB = await ethers.getContractFactory("WBNB");
    wbnb = await WBNB.deploy();

    const Router = await ethers.getContractFactory("CrossRouter");
    router = await Router.deploy(factory.address, wbnb.address);
    console.log("\nRouter Deployed: ", router.address);

    factory.setRouter(router.address);
    console.log("\nFactory Router Set: ", router.address);

    const thr = utils.parseEther("100");
    const Crss = await ethers.getContractFactory("CrssToken");
    crss = await upgrades.deployProxy(Crss, [router.address, devTo, buybackTo, thr]);
    console.log("\ncrss Deployed: ", crss.address);

    router.setCrssContract(crss.address);
    console.log("\nCRSS token is set on Router:", crss.address);

    const MockToken = await ethers.getContractFactory("MockToken");
    mock = await MockToken.deploy("Mock", "MCK");
    console.log("\nmock token deployed: ", mock.address);

    console.log("\nTesting Start\n");

    console.log("\nFactory Code Hash: ", await factory.INIT_CODE_PAIR_HASH());
  });

  it("Deployer got 1e6 Crss minted", async () => {
    const crssMinted = await crss.balanceOf(deployer.address);
    console.log("Cross Token Minted: ", utils.formatEther(crssMinted));
    expect(crssMinted).to.equal(utils.parseEther((1e6).toString()));
  });

  it("Mint MCK and approve it to router", async () => {
    await mock.mint(deployer.address, utils.parseEther("10000"));
    await mock.approve(router.address, utils.parseEther("10000"));
    await crss.approve(router.address, utils.parseEther("100000"));
    expect(await crss.allowance(deployer.address, router.address)).to.equal(utils.parseEther("100000"));
    expect(await mock.allowance(deployer.address, router.address)).to.equal(utils.parseEther("10000"));
  });

  it("Crss-MCK LP Balance should be less than 500", async () => {
    const block = await ethers.provider.getBlock("latest");
    await router.addLiquidity(
      crss.address,
      mock.address,
      utils.parseEther("500"),
      utils.parseEther("500"),
      0,
      0,
      deployer.address,
      block.timestamp + 1000
    );

    const pairAddr = factory.getPair(crss.address, mock.address);
    crss_mockPair = new ethers.Contract(pairAddr, pairAbi, deployer);
    const lpBalance = await crss_mockPair.balanceOf(deployer.address);

    const expectedLP = sqrt(utils.parseEther("500").mul(utils.parseEther("500").mul(999).div(1000)));
    console.log("expectedLP: ", expectedLP);
    expect(lpBalance).to.equal(expectedLP.sub(1000));
  });

  it("DevTo Balance should be 2", async () => {
    expect(await crss.balanceOf(devTo)).to.equal(utils.parseEther("0.2"));
  });

  it("BuyBackTo Balance should be 1.5", async () => {
    expect(await crss.balanceOf(buybackTo)).to.equal(utils.parseEther("0.15"));
  });

  it("Liquify Balance should be 1.5", async () => {
    expect(await crss.balanceOf(crss.address)).to.equal(utils.parseEther("0.15"));
  });

  it("Crss-BNB LP Balance should be 10000", async () => {
    const block = await ethers.provider.getBlock("latest");
    await crss.approve(router.address, utils.parseEther("100000"));
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
    const pairAddr = factory.getPair(crss.address, wbnb.address);
    crss_ethPair = new ethers.Contract(pairAddr, pairAbi, deployer);
    const lpBalance = await crss_ethPair.balanceOf(deployer.address);

    const expectedLP = sqrt(utils.parseEther("1000").mul(utils.parseEther("100000").mul(999).div(1000)));
    console.log("expectedLP: ", expectedLP);
    expect(lpBalance).to.equal(expectedLP.sub(1000));
  });

  it("Swap Crss for BNB", async () => {
    const block = await ethers.provider.getBlock("latest");
    await crss.approve(router.address, utils.parseEther("100"));
    await expect(
      router.swapExactTokensForETH(
        utils.parseEther("1"),
        0,
        [crss.address, wbnb.address],
        deployer.address,
        block.timestamp + 1000
      )
    ).to.be.revertedWith("Cross: K");
  });

  it("Swap Crss for BNB", async () => {
    const block = await ethers.provider.getBlock("latest");
    await crss.approve(router.address, utils.parseEther("100"));
    const amountOut = await router.getAmountsOut(utils.parseEther("1"), [crss.address, wbnb.address]);

    const oldBalance = await ethers.provider.getBalance(deployer.address);
    await router.swapExactTokensForETHSupportingFeeOnTransferTokens(
      utils.parseEther("1"),
      0,
      [crss.address, wbnb.address],
      deployer.address,
      block.timestamp + 1000
    );
    const newBalance = await ethers.provider.getBalance(deployer.address);
    const ethOutput = newBalance.sub(oldBalance);
    console.log("Balances: ", utils.formatEther(newBalance), utils.formatEther(oldBalance));
    const gas = await router.estimateGas.swapExactTokensForETHSupportingFeeOnTransferTokens(
      utils.parseEther("1"),
      0,
      [crss.address, wbnb.address],
      deployer.address,
      block.timestamp + 1000
    );
    console.log("Gas Estimation: ", utils.formatEther(gas), utils.formatEther(amountOut[1].sub(ethOutput)));

    // expect(ethOutput.add(gas)).to.equal(amountOut[1])
  });

  it("Set Liquify Threshold with non-owner account", async () => {
    const thr = utils.parseEther("100");
    await expect(crss.connect(alice).setLiquifyThreshold(thr)).to.be.revertedWith("Ownable: caller is not the owner");
  });

  it("Transfer 1e5 Crss to Alice", async () => {
    await crss.transfer(alice.address, utils.parseEther("100000"));
    const aliceBalance = await crss.balanceOf(alice.address);
    const expectedBalance = utils.parseEther("99900");
    expect(aliceBalance).to.equal(expectedBalance);
  });

  it("Trigger 2 Transfers at the same time", async () => {
    const fromDeployer = crss.transfer(bob.address, utils.parseEther("50000"));
    const fromAlice = crss.connect(alice).transfer(bob.address, utils.parseEther("4999"));
    const expectedBalance = ((54999 * 999) / 1000).toString();
    await Promise.all([fromAlice]);
    expect(await crss.balanceOf(bob.address)).to.equal(utils.parseEther(expectedBalance));
  });

  it("Transaction Origin should be Alice", async () => {
    const txOrigin = await crss.consecutiveTxes();
    expect(txOrigin).to.equal(alice.address);
  });

  it("Trigger Transfers by same trasaction origin with previous one", async () => {
    await expect(crss.connect(alice).transfer(bob.address, utils.parseEther("100"))).to.be.revertedWith(
      "CrssToken: Exceed MaxTransferAmount"
    );
  });

  it("Transfer until liquify threshold is matched", async () => {
    await crss.transfer(alice.address, utils.parseEther("200000"));
    // expect(await crss.balanceOf(crss.address)).to.equal(utils.parseEther("0"))
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

const Presale = artifacts.require("Presale");

const crss = "0x0999ba9aEA33DcA5B615fFc9F8f88D260eAB74F1";
const busd = "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56";
const masterWallet= "0x2A479056FaC97b62806cc740B11774E6598B1649"; 
const presaleStart = 1635336000; //Date and time (GMT): Wednesday, October 27, 2021 12:00:00 PM
module.exports = async function(deployer) {
  const block = await web3.eth.getBlock("latest");
  await deployer.deploy(Presale, crss, busd, masterWallet, presaleStart);
};

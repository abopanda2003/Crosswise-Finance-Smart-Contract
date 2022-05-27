const PresaleV2 = artifacts.require("PresaleV2");

const crss = "0x0999ba9aEA33DcA5B615fFc9F8f88D260eAB74F1";
const busd = "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56";
const masterWallet= "0x2A479056FaC97b62806cc740B11774E6598B1649"; 
const presaleStart = 1637827200; //Date and time (GMT): Thursday, November 25, 2021 08:00:00 AM
module.exports = async function(deployer) {
  await deployer.deploy(PresaleV2, crss, busd, masterWallet, presaleStart);
};


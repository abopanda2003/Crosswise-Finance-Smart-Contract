const MasterChef = artifacts.require("MasterChef");

module.exports = async function(deployer) {
  const block = await web3.eth.getBlock("latest");
  await deployer.deploy(MasterChef, "0x55eccd64324d35cb56f3d3e5b1544a9d18489f71", "0xc3ed653104C31102D462600C64B38b3DE5025f57", "0x3822eD369a46D9B5347850eEFA3D0ACc4964c24b", "0x2A479056FaC97b62806cc740B11774E6598B1649", "0x2A479056FaC97b62806cc740B11774E6598B1649", block.number + 100);
};

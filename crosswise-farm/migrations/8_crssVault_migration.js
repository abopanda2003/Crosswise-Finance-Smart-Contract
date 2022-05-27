const CrssVault = artifacts.require("CrssVault");

module.exports = async function(deployer) {
  await deployer.deploy(CrssVault, "0x55eccd64324d35cb56f3d3e5b1544a9d18489f71", "0xc3ed653104C31102D462600C64B38b3DE5025f57", "0x306e3566323449ba1786795db64a42a2704d1bb2", "0x6973a5D5e2Bd3bBDe498104FeCDF3132A3c545aB");
};

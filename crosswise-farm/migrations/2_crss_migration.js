const CrssToken = artifacts.require("CrssToken");

module.exports = async function(deployer) {
  deployer.deploy(CrssToken, '0x2A479056FaC97b62806cc740B11774E6598B1649', '0x000000000000000000000000000000000000dEaD', '0x0999ba9aEA33DcA5B615fFc9F8f88D260eAB74F1', '0x55eCCd64324d35CB56F3d3e5b1544a9D18489f71');
};

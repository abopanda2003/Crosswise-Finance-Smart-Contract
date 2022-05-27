const xCrssToken = artifacts.require("xCrssToken");

module.exports = async function(deployer) {
  deployer.deploy(xCrssToken);
};

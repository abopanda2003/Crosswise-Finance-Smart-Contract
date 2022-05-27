// truffle migrate --f 2 --to 2 --network testnet
const SousChef = artifacts.require('SousChef');

require('dotenv').config()

let STAKING = '0xa98d21c3d61a7eb9dd3be9c9a1132abb7c7be2dd';
let EARNING = '0xeD24FC36d5Ee211Ea25A80239Fb8C4Cfd80f12Ee';

module.exports = async function (deployer, network, accounts) {
    await deploy_souschef(deployer, network, accounts);
};

async function deploy_souschef(deployer, network, accounts) {
    const block = await web3.eth.getBlock("latest");
    await deployer.deploy(SousChef,  STAKING, EARNING, web3.utils.toWei('0.0001'), block.number, block.number + 57600);
}

// web3.utils.toWei('0.0119047')

const hre = require("hardhat");

async function main() {
    // We get the contract to deploy
    const Router = await hre.ethers.getContractFactory("CrosswiseRouter");

    //Add Factory, WBNB, Admin address and _priceConsumer
    const router = await Router.deploy();

    await router.deployed();

    console.log("Router deployed to:", router.address);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./CrossFarm.sol";

// import "@nomiclabs/buidler/console.sol";

// MasterChef is the master of Crss. He can make Crss and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once CRSS is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract CrossFarm2 is CrossFarm {
    function getVersion() external pure returns (string memory) {
        return "Farm VERSION 2";
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./xCrssToken.sol";

// xCrssToken with Governance.
contract xCrssToken2 is xCrssToken {
    function getVersion() external pure returns (string memory) {
        return "VERSION 2";
    }
}

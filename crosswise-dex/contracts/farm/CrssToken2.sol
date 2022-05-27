// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./CrssToken.sol";

contract CrssToken2 is CrssToken {
    function getVersion() external pure returns (string memory) {
        return "VERSION 2";
    }
}

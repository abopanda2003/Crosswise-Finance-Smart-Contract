// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IPancakePair.sol";

interface ICrossPair is IPancakePair {
    function setRouter(address _router) external;
    function getCrssReserve(address crss) external view returns (uint256 reserve);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IPancakeFactory.sol";

interface ICrossFactory is IPancakeFactory {
    function setRouter(address _router) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ISessionConstants.sol";
interface ISessionRegistrar {

    function openSession(SessionType sessionType) external returns (SessionParams memory dsParams);
    function closeSession() external;
    function getInnermostSType() external returns (SessionType);  
    function getOutermostSType() external returns (SessionType);
}
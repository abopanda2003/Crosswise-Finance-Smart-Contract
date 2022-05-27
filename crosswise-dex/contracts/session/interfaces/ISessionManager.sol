// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ISessionRegistrar.sol";
import "./ISessionConstants.sol";


interface ISessionManager {
    function setFeeRates(uint256 sessionEnum, FeeRates memory feeRates) external;
    function setFeeStores(FeeStores memory feeStores) external;
    function initializeFees(FeeStores memory feeStores, FeeRates[NumberSessionTypes] memory feeRatesArray) external;
}
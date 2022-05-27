pragma solidity ^0.8.0;

import "./ISessionConstants.sol";
interface ISessionFeeOffice {
    function payFeeImplementation(address account, uint256 principal, FeeRates memory rates ) external returns (uint256 feesPaid);
}
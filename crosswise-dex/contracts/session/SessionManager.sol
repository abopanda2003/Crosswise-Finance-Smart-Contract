 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/ISessionConstants.sol";
import "./interfaces/ISessionRegistrar.sol";
import "./interfaces/ISessionFeeOffice.sol";
import "./interfaces/ISessionManager.sol";

abstract contract SessionManager is ISessionManager {

    SessionParams dsParams;
    ISessionRegistrar sessionRegistrar;
    ISessionFeeOffice sessionFeeOffice;
    FeeStores public feeStores;
    FeeRates[NumberSessionTypes] public feeRatesArray;
    uint256 constant squareFeeMagnifier = FeeMagnifier * FeeMagnifier;

    // ----------------------------- Liquidity control attributes -------------------------
    struct PairLiquidityOriginSession {
        uint256 liquidity;
        uint256 originSession;
    }
    mapping(address => PairLiquidityOriginSession) initialPairLiquidities;
    uint256 public originSessionLiquidityChangeLimit = 200; // rate based on FeeMagnifier.


    modifier session(SessionType sessionType) {
        dsParams = sessionRegistrar.openSession(sessionType);
        _;
        sessionRegistrar.closeSession();
    }

    modifier OnlyGovernance virtual;

    function setFeeStores(FeeStores memory _feeStores) public override virtual OnlyGovernance {
        require(_feeStores.developer != address(0) && _feeStores.buyback != address(0) && _feeStores.liquidity != address(0), "Zero address");
        feeStores = _feeStores;
    }

    function setFeeRates(uint256 sessionEnum, FeeRates memory feeRates) public override virtual OnlyGovernance {
        require(sessionEnum < feeRatesArray.length, "Wrong SessionType");
        require(feeRates.developer + feeRates.buyback + feeRates.liquidity < FeeMagnifier, "Fee rates exceed limit");

        feeRatesArray[sessionEnum] = feeRates;
    }

    function initializeFees(FeeStores memory _feeStores, FeeRates[NumberSessionTypes] memory _feeRatesArray) public override virtual OnlyGovernance {
        setFeeStores(_feeStores);
        for(uint256 i = 0; i < NumberSessionTypes; i ++) {
            feeRatesArray[i] = _feeRatesArray[i];
        }
    }
    function _payFee(address account, uint256 principal, FeeRates memory rates ) internal virtual returns (uint256 feesPaid) {
        return sessionFeeOffice.payFeeImplementation(account, principal, rates);
    }

    function _getInnerFeeRemoved(uint256 principal, FeeRates memory rates) internal view virtual returns (uint256) {
        uint256 totalRates = rates.developer + rates.buyback + rates.liquidity;
        return principal * totalRates / FeeMagnifier;
    }
    function _getOuterFeeAdded(uint256 principal, FeeRates memory rates) internal view virtual returns (uint256) {
        uint256 totalRates = rates.developer + rates.buyback + rates.liquidity;
        return principal * totalRates / (FeeMagnifier - totalRates);
    }

    function _initializeOSLiquidity(address pair, uint256 reserve0, uint256 reserve1) internal virtual {
        if (initialPairLiquidities[pair].originSession != dsParams.originSession ) {
            initialPairLiquidities[pair].liquidity = uint256(reserve0) * uint256(reserve1);
            initialPairLiquidities[pair].originSession = dsParams.originSession;
        }
    }

    function _ruleOutInvalidLiquidity(address pair, uint256 reserve0, uint256 reserve1) internal view virtual {
        uint256 liquidity = uint256(reserve0) * uint256(reserve1);
        uint256 prevLiquidity = initialPairLiquidities[pair].liquidity;
        uint256 squareLimit = originSessionLiquidityChangeLimit * originSessionLiquidityChangeLimit;
        uint256 min = prevLiquidity * squareFeeMagnifier / squareLimit;
        uint256 max = prevLiquidity * squareLimit / squareFeeMagnifier;
        require(min <= liquidity && liquidity <= max, "CrossRouter: Deviation from initial liquidity");
    }
}
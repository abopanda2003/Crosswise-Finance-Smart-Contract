 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/ISessionConstants.sol";
import "./interfaces/ISessionRegistrar.sol";

abstract contract SessionRegistrar is ISessionRegistrar {

    uint256 originSession;
    uint256[] originSessionsLastSeenBySType;

    SessionType[10] private stackSTypes;
    uint256 stackPointer;

    modifier dsManagersOnly virtual;

    function openSession(SessionType sessionType) public override virtual dsManagersOnly returns (SessionParams memory dsParams) {
        require(sessionType != SessionType.None, "Cross: Invalid SessionType Type");
        // reading stackPointer costs 5,000 gas, while updating costs 20,000 gas.
        if ( ! (stackPointer == 0 && stackSTypes[0] == SessionType.None) ) stackPointer ++;
        require(stackPointer < stackSTypes.length, "Cross: Session stack overflow");
        require(stackSTypes[stackPointer] == SessionType.None, "Cross: Session stack inconsistent");

        stackSTypes[stackPointer] = sessionType;

        dsParams.sessionType = sessionType;
        (dsParams.originSession, dsParams.lastOriginSession) = _seekInitializeOriginSession(sessionType);
        dsParams.isOriginAction = _isOriginAction();

        _initializeSession(sessionType);
    }

    function closeSession() public override dsManagersOnly {
        // reading stackPointer costs 5,000 gas, while updating costs 20,000 gas.
        require(stackPointer < stackSTypes.length, "Cross: Session stack overflow");
        SessionType sessionType = stackSTypes[stackPointer];
        require(sessionType != SessionType.None, "Cross: Session stack inconsistent");
        stackSTypes[stackPointer] = SessionType.None;

        if (stackPointer > 0) stackPointer --;      
        originSessionsLastSeenBySType[uint256(sessionType)] = originSession;

        _finalizeSession(sessionType);
    }

    function getInnermostSType() public view override returns (SessionType) {
        return stackSTypes[stackPointer];
    }

    function getOutermostSType() public view override returns (SessionType) {
        return stackSTypes[0];
    }

    function _isOriginAction() internal view returns (bool) {
        return stackPointer == 0 && stackSTypes[stackPointer] != SessionType.None;
    }

    function _initializeSession(SessionType sessionType) internal virtual {
    }

    function _finalizeSession(SessionType sessionType) internal virtual {
    }

    function _seekInitializeOriginSession(SessionType sessionType) internal virtual returns (uint256 _originSession, uint256 _lastOriginSession) {

        uint256 hashBNOrigin = uint256(keccak256(abi.encode(block.number, tx.origin)));
        if (originSession != hashBNOrigin ) {
            originSession = hashBNOrigin;
        }
        _originSession = originSession;
        _lastOriginSession = originSessionsLastSeenBySType[uint256(sessionType)];
    }
}
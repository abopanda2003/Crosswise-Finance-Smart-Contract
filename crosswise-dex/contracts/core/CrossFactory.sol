// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/ICrossFactory.sol";
import "../periphery/interfaces/ICrossRouter.sol";
import "./CrossPair.sol";

contract CrossFactory is ICrossFactory {
    bytes32 public constant INIT_CODE_PAIR_HASH = keccak256(abi.encodePacked(type(CrossPair).creationCode));

    address public override feeTo;
    address public override feeToSetter;

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;
    address public router;

    // This event emits when the router address changes
    event SetRouter(address prevRouter, address router);

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        require(router != address(0), "Cross: NO_ROUTER");
        require(tokenA != tokenB, "Cross: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Cross: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "Cross: PAIR_EXISTS"); // single check is sufficient
        bytes memory bytecode = type(CrossPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        ICrossPair(pair).initialize(token0, token1);
        ICrossPair(pair).setRouter(router);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        ICrossRouter(router).informOfPair(pair, token0, token1);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == feeToSetter, "Cross: FORBIDDEN");
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        require(msg.sender == feeToSetter, "Cross: FORBIDDEN");
        feeToSetter = _feeToSetter;
    }

    function setRouter(address _router) external override {
        require(msg.sender == feeToSetter, "Cross: FORBIDDEN");
        // Zero address and previous address can not be set new router
        require(_router != address(0) && _router != router, "Cross: Not valid router address");
        address prevRouter = router;
        router = _router;
        emit SetRouter(prevRouter, router);
        for (uint256 i = 0; i < allPairs.length; i++) {
            ICrossPair(allPairs[i]).setRouter(router);
        }
    }
}

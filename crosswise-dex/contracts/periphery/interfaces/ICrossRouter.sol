// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IPancakeRouter02.sol";

interface ICrossRouter is IPancakeRouter02 {
    function setCrssContract(address _crssContract) external;
    function getOwner() external view returns (address);
    function informOfPair(address pair, address token0, address token1) external;
    function getReserveOnETHPair(address token) external view returns (uint256 reserve);

    function addLiquiditySupportingFeeOnTransferTokens(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function addLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );

    function removeLiquiditySupportingFeeOnTransferTokens(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IMigratorChef {
    // Perform LP token migration from legacy CrosswiseSwap to CrssSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to CrosswiseSwap LP tokens.
    // CrssSwap must mint EXACTLY the same amount of CrssSwap LP tokens or
    // else something bad will happen. Traditional CrosswiseSwap does not
    // do that so be careful!
    function migrate(IERC20Upgradeable token) external returns (IERC20Upgradeable);
}

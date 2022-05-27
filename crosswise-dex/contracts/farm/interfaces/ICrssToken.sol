// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface ICrssToken is IERC20Upgradeable {

    function getOwner() external view returns (address);

    function router() external view returns (address);

    function farm() external view returns (address);

    function crssBnbPair() external view returns (address);

    function crssBusdPair() external view returns (address);

    function maxSupply() external view returns (uint256);

    function maxTransferAmountRate() external view returns (uint256);

    function setRouter(address _router) external;

    function setFarm(address crssFarm) external;

    function mint(address _to, uint256 _amount) external;

    function burn(address _from, uint256 _amount) external;

    function informOfPair(address pair, address token0, address token1) external;
}

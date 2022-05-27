pragma solidity 0.6.12;

import "./BEP20.sol";

contract MockBEP20 is BEP20 {
    constructor(
        string memory name,
        string memory symbol
    ) public BEP20(name, symbol) {}

    function mint(address account, uint256 supply) public {
        _mint(account, supply);
    }
}

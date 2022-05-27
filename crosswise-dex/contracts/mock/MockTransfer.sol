// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../farm/interfaces/ICrssToken.sol";
import "../farm/interfaces/ICrossFarm.sol";
import "hardhat/console.sol";

contract MockTransfer is Ownable {
    ICrssToken private _crssToken;

    constructor(ICrssToken _token) {
        _crssToken = _token;
    }
    receive() external payable {}

    function transferTo(address _to, uint256 _amount) external {
        _crssToken.transfer(_to, _amount);
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) external {
        _crssToken.transferFrom(_from, _to, _amount);
    }

    function transferCross(
        address _userA,
        address _userB,
        address _userC,
        uint256 _amountB,
        uint256 _amountC
    ) external {
        // transfer tokens from userA to userB
        _crssToken.transferFrom(_userA, _userB, _amountB);

        // transfer tokens from userA to userC
        _crssToken.transferFrom(_userA, _userC, _amountC);
    }

    fallback() external payable {
        console.log("fallback function called");
        console.log("my crss balance", _crssToken.balanceOf(address(this)));
    }

    function withdrawVest(
        ICrossFarm _farm,
        uint256 _pid,
        uint256 _amount
    ) external {
        _farm.withdrawVest(_pid, _amount);
    }
}

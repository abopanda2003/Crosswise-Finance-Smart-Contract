// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "./IMigratorChef.sol";
import "../xCrssToken.sol";

interface ICrossFarm {
    function setXCrss(address _xcrss) external;

    function updateMultiplier(uint256 multiplierNumber) external;

    function poolLength() external view returns (uint256);

    function add(
        uint256 _allocPoint,
        IERC20Upgradeable _lpToken,
        bool _withUpdate,
        uint256 _depositFeeRate,
        address _strategy
    ) external;

    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate,
        uint256 _depositFeeRate,
        address _strategy
    ) external;

    function setMigrator(IMigratorChef _migrator) external;

    function migrate(uint256 _pid) external;

    function getMultiplier(uint256 _from, uint256 _to) external view returns (uint256);

    function pendingCrss(uint256 _pid, address _user) external view returns (uint256);

    function massUpdatePools() external;

    function updatePool(uint256 _pid) external;

    function deposit(
        uint256 _pid,
        uint256 _amount,
        bool _isAuto,
        address _referrer,
        bool _isVest
    ) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function withdrawVest(uint256 _pid, uint256 _amount) external;

    function earn(uint256 _pid) external;

    function enterStaking(uint256 _amount) external;

    function leaveStaking(uint256 _amount) external;

    function emergencyWithdraw(uint256 _pid) external;

    function dev(address _devaddr) external;
}

pragma solidity 0.6.12;

interface IMasterChef {
    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256, uint256, bool, bool);

    function emergencyWithdraw(uint256 _pid) external;

    function enterStaking(uint256 _amount) external;

    function leaveStaking(uint256 _amount) external;

    function pendingCrss(uint256 _pid, address _user) external view returns (uint256);
}
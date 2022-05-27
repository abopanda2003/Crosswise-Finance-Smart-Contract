pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./BaseRelayRecipient.sol";

import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import './libs/AddrArrayLib.sol';
import "./interface/IMasterChef.sol";
import "./xCrssToken.sol";


contract CrssVault is ReentrancyGuard, BaseRelayRecipient {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;
    using AddrArrayLib for AddrArrayLib.Addresses;

    struct UserInfo {
        uint256 shares; // number of shares for a user
        uint256 lastDepositedTime; // keeps track of deposited time for potential penalty
        uint256 CrssAtLastUserAction; // keeps track of Crss deposited at the last user action
        uint256 lastUserActionTime; // keeps track of the last user action time
        bool isVest;
    }

    IBEP20 public immutable token; // Crss token
    xCrssToken public immutable xCrss;

    IMasterChef public immutable masterchef;

    mapping(address => UserInfo) public userInfo;
    AddrArrayLib.Addresses private depositors;

    uint256 public totalShares;
    uint256 public lastHarvestedTime;
    
    address private _owner;

    address public devAddress;

    address public constant burnAddress = 0x000000000000000000000000000000000000dEaD;

    uint256 public autoCompFee = 500; // 2%

    event Deposit(address indexed sender, uint256 amount, uint256 shares, uint256 lastDepositedTime);
    event Withdraw(address indexed sender, uint256 amount, uint256 shares);
    event Harvest(address indexed sender, uint256 performanceFee, uint256 callFee);
    event UpdateAutoCompFee(uint256 autoCompFee);
    event SetDevAddress(address indexed devAddress);
    event SetTrustedForwarder(address indexed trustedForwarder);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @notice Constructor
     * @param _token: Crss token contract
     * @param _xCrss: xCrss token contract
     * @param _masterchef: MasterChef contract
     * @param _devAddress: address of the dev (collects fees)
     */
    constructor(
        IBEP20 _token,
        xCrssToken _xCrss,
        IMasterChef _masterchef,
        address _devAddress
    ) public {
        _owner = _msgSender();

        token = _token;
        xCrss = _xCrss;
        masterchef = _masterchef;
        devAddress = _devAddress;

        // Infinite approve
        IBEP20(_token).safeApprove(address(_masterchef), uint256(-1));

        emit OwnershipTransferred(address(0), _owner);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(owner() == _msgSender(), "caller is not the owner");
        _;
    }

    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function versionRecipient() external view override returns (string memory) {
        return "1";
    }

    /**
     * @notice Deposits funds into the Crss Vault
     
     * @param _amount: number of tokens to deposit (in Crss)
     */
    function deposit(uint256 _amount, bool _isVest) external  {
        require(_amount > 0, "Nothing to deposit");
        UserInfo storage user = userInfo[_msgSender()];
        if(user.shares > 0) {
            require(user.isVest == _isVest, "Cannot change vesting option in progress");
        }

        uint256 pool = balanceOf();
        uint256 oldBalance = token.balanceOf(address(this));
        token.safeTransferFrom(_msgSender(), address(this), _amount);
        uint256 newBalance = token.balanceOf(address(this));
        _amount = newBalance.sub(oldBalance);
        
        uint256 currentShares = 0;
        if (totalShares != 0) {
            currentShares = (_amount.mul(totalShares)).div(pool);
        } else {
            currentShares = _amount;
        }
        

        user.shares = user.shares.add(currentShares);
        user.lastDepositedTime = block.timestamp;
        
        totalShares = totalShares.add(currentShares);

        user.CrssAtLastUserAction = user.shares.mul(balanceOf()).div(totalShares);
        user.lastUserActionTime = block.timestamp;
        user.isVest = _isVest;
        userIndex(_msgSender());
        _earn();

        emit Deposit(_msgSender(), _amount, currentShares, block.timestamp);
    }

    /**
     * @notice Withdraws all funds for a user
     */
    function withdrawAll() external {
        withdraw(userInfo[_msgSender()].shares);
    }

    /**
     * @notice Reinvests Crss tokens into MasterChef
     
     */
    function harvest() external  {
        IMasterChef(masterchef).leaveStaking(0);

        uint256 bal = available();
        uint256 fee = bal.mul(autoCompFee).div(10000);
        token.safeTransfer(devAddress, fee);

        bal = available();
        address[] memory users = depositors.getAllAddresses();
        for(uint256 i = 0; i < users.length ; i++) {
            UserInfo storage user = userInfo[users[i]];
            uint256 reward = bal.mul(user.shares).div(totalShares);
            if(user.isVest) {
                uint256 vest = reward.div(2);
                token.approve(address(xCrss), vest);
                xCrss.depositToken(users[i], vest);
            }
            else {
                uint256 burn = reward.mul(25).div(100);
                token.safeTransfer(burnAddress, burn);
            }
        }

        _earn();

        lastHarvestedTime = block.timestamp;
        // emit Harvest(_msgSender(), currentPerformanceFee, currentCallFee);
    }


    function setTrustedForwarder(address _trustedForwarder) external {
        require(_trustedForwarder != address(0));
        trustedForwarder = _trustedForwarder;
        emit SetTrustedForwarder(_trustedForwarder);
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) external onlyOwner {
        require(_msgSender() == devAddress, "setDevAddress: FORBIDDEN");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        devAddress = _devAddress;
        emit SetDevAddress(_devAddress);
    }

    // Update auto compounding fee.
    function updateAutoCompFee(uint256 _autoCompFee) external onlyOwner {
        autoCompFee = _autoCompFee;
        emit UpdateAutoCompFee(autoCompFee);
    }

    /**
     * @notice Withdraws from MasterChef to Vault without caring about rewards.
     * @dev EMERGENCY ONLY. Only callable by the contract admin.
     */
    function emergencyWithdraw() external onlyOwner {
        IMasterChef(masterchef).emergencyWithdraw(0);
    }

    /**
     * @notice Withdraw unexpected tokens sent to the Crss Vault
     */
    function inCaseTokensGetStuck(address _token) external onlyOwner {
        require(_token != address(token), "Token cannot be same as deposit token");

        uint256 amount = IBEP20(_token).balanceOf(address(this));
        IBEP20(_token).safeTransfer(_msgSender(), amount);
    }


    /**
     * @notice Calculates the total pending rewards that can be restaked
     * @return Returns total pending Crss rewards
     */
    function calculateTotalPendingCrssRewards() external view returns (uint256) {
        uint256 amount = IMasterChef(masterchef).pendingCrss(0, address(this));
        amount = amount.add(available());

        return amount;
    }

    /**
     * @notice Calculates the price per share
     */
    function getPricePerFullShare() external view returns (uint256) {
        return totalShares == 0 ? 1e18 : balanceOf().mul(1e18).div(totalShares);
    }

    function stakedTokens(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];

        return user.shares.mul(balanceOf()).div(totalShares);
    }

    /**
     * @notice Withdraws from funds from the Crss Vault
     * @param _shares: Number of shares to withdraw
     */
    function withdraw(uint256 _shares) public {
        UserInfo storage user = userInfo[_msgSender()];
        require(_shares > 0, "Nothing to withdraw");
        require(_shares <= user.shares, "Withdraw amount exceeds balance");

        uint256 currentAmount = (balanceOf().mul(_shares)).div(totalShares);
        user.shares = user.shares.sub(_shares);
        totalShares = totalShares.sub(_shares);

        uint256 bal = available();
        if (bal < currentAmount) {
            uint256 balWithdraw = currentAmount.sub(bal);
            IMasterChef(masterchef).leaveStaking(balWithdraw);
            uint256 balAfter = available();
            uint256 diff = balAfter.sub(bal);
            if (diff < balWithdraw) {
                currentAmount = bal.add(diff);
            }
        }

        if (user.shares > 0) {
            user.CrssAtLastUserAction = user.shares.mul(balanceOf()).div(totalShares);
        } else {
            user.CrssAtLastUserAction = 0;
        }

        user.lastUserActionTime = block.timestamp;

        userIndex(_msgSender());

        token.safeTransfer(_msgSender(), currentAmount);

        emit Withdraw(_msgSender(), currentAmount, _shares);
    }

    /**
     * @notice Custom logic for how much the vault allows to be borrowed
     * @dev The contract puts 100% of the tokens to work.
     */
    function available() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @notice Calculates the total underlying tokens
     * @dev It includes tokens held by the contract and held in MasterChef
     */
    function balanceOf() public view returns (uint256) {
        (uint256 amount,,,, ) = IMasterChef(masterchef).userInfo(0, address(this));
        return token.balanceOf(address(this)).add(amount);
    }

    /**
     * @notice Deposits tokens into MasterChef to earn staking rewards
     */
    function _earn() internal {
        uint256 bal = available();
        if (bal > 0) {
            IMasterChef(masterchef).enterStaking(bal);
        }
    }

    /**
     * @notice Checks if address is a contract
     * @dev It prevents contract from being targetted
     */
    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    function userIndex( address _user ) internal {
        uint256 amount = userInfo[_user].shares;
        if( amount > 0 ){ // add user
            depositors.pushAddress(_user);
        }else if( amount == 0 ){ // remove user
            depositors.removeAddress(_user);
        }
    }
}
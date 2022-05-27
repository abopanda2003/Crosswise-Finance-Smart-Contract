// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
//import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../session/SessionManager.sol";
import "./BaseRelayRecipient.sol";
import "./interfaces/ICrossFarm.sol";
import "./interfaces/IStrategy.sol";
import "./interfaces/ICrssToken.sol";
import "./interfaces/IXCrssToken.sol";
import "./interfaces/ICrssReferral.sol";
import "./interfaces/IMigratorChef.sol";
import "../core/interfaces/ICrossPair.sol";
import "../periphery/interfaces/ICrossRouter.sol";
import "../libraries/math/SafeMath.sol";

import "hardhat/console.sol";

// MasterChef is the master of Crss. He can make Crss and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once CRSS is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract CrossFarm is ICrossFarm, BaseRelayRecipient, SessionManager {
    using SafeMath for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // CrssToken Vest
    struct CrssVest {
        uint256 totalAmount;
        uint256 withdrawAmount;
        uint256 lastWithdraw;
    }

    uint256 private constant month = 30 days;
    uint256 public constant unlockPerMonth = 2000;

    // Need to discuss how much will be the maximum fee rate
    uint256 private constant depositFeeLimit = 500;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        bool isAuto;
        bool isVest;
        CrssVest[] vestList;
        //
        // We do some fancy math here. Basically, any point in time, the amount of CRSSs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accCrssPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accCrssPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20Upgradeable lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. CRSSs to distribute per block.
        uint256 lastRewardBlock; // Last block number that CRSSs distribution occurs.
        uint256 accCrssPerShare; // Accumulated CRSSs per share, times 1e12. See below.
        uint256 depositFeeRate; // Fee Rate when deposit
        address strategy; // Strategy address
    }

    // Owner Address: Could not use ownable because of duplicate usage of _msgSender()
    address private _owner;

    // The CRSS TOKEN!
    address public crss;
    // The XCRSS TOKEN!
    address public xcrss;
    // Dev address.
    address public devaddr;
    // Treasure Address.
    address public treasuryAddr;
    // Router address.
    address public router;
    // CRSS tokens created per block.
    uint256 public crssPerBlock;
    // Bonus muliplier for early crss makers.
    uint256 public bonusMultiplier;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;
    
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;
    // The block number when CRSS mining starts.
    uint256 public startBlock;

    // Crss referral contract address.
    address public crssReferral;

    // Referral commission rate in basis points.
    uint256 public referralCommissionRate;
    // Max referral commission rate: 10%.
    uint256 public maximumReferralCommisionRate;

    // Magnifier
    uint256 private FeeMagnifier;
    // Auto Compounding Fee Rate
    uint256 private autoFeeRate;
    // Auto Compounding Burn Rate
    uint256 private autoBurnRate;
    // Router Action Deadline
    uint256 public routerDeadlineDuration;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetcrssReferral(address indexed crssReferral);
    event SetReferralCommissionRate(uint256 referralCommissionRate);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);
    event SetTrustedForwarder(address _trustedForwarder);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(_msgSender() == owner(), "Ownable: caller is not the owner");
        _;
    }

    modifier OnlyGovernance override virtual {
        require(_msgSender() == crss, "Cross: FORBIDDEN");
        _;
    }

    modifier validatePoolByPid(uint256 _pid) {
        require(_pid < poolInfo.length, "pool id not exisit");
        _;
    }

    function initialize(
        address _crss,
        address _devaddr,
        address _treasuryAddr,
        address _router,
        uint256 _crssPerBlock,
        uint256 _startBlock
    ) external {
        require(_msgSender() == ICrssToken(_crss).getOwner(), "Cross: FORBIDDEN");
        _owner = _msgSender();

        sessionRegistrar = ISessionRegistrar(_crss);
        sessionFeeOffice = ISessionFeeOffice(_crss);

        crss = _crss;
        router = _router;
        devaddr = _devaddr;
        treasuryAddr = _treasuryAddr;
        crssPerBlock = _crssPerBlock;
        startBlock = _startBlock;

        FeeMagnifier = 10000;
        referralCommissionRate = 100;
        maximumReferralCommisionRate = 1000;
        autoFeeRate = 500;
        autoBurnRate = 2500;
        routerDeadlineDuration = 300;

        // staking pool
        poolInfo.push(
            PoolInfo({
                lpToken: IERC20Upgradeable(_crss),
                allocPoint: 1000,
                lastRewardBlock: startBlock,
                accCrssPerShare: 0,
                depositFeeRate: 0,
                strategy: address(0)
            })
        );
        bonusMultiplier = 1;
        totalAllocPoint = 1000;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function setXCrss(address _xcrss) external override onlyOwner {
        require(_msgSender() == IXCrssToken(_xcrss).getOwner(), "Cross: FORBIDDEN");
        xcrss = _xcrss;
    }

    function updateMultiplier(uint256 multiplierNumber) public override onlyOwner {
        bonusMultiplier = multiplierNumber;
    }

    function poolLength() external view override returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20Upgradeable _lpToken,
        bool _withUpdate,
        uint256 _depositFeeRate,
        address _strategy
    ) public override onlyOwner {
        require(_depositFeeRate <= depositFeeLimit, "set: invalid deposit fee basis points");

        // Check if this duplicate same lp token
        for (uint i = 0; i < poolInfo.length; i++) {
            if (poolInfo[i].lpToken == _lpToken) {
                revert("Cross: Not allowed to duplicate LP token");
            }
        }

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accCrssPerShare: 0,
                depositFeeRate: _depositFeeRate,
                strategy: _strategy
            })
        );
        updateStakingPool();
    }

    // Update the given pool's CRSS allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate,
        uint256 _depositFeeRate,
        address _strategy
    ) public override onlyOwner validatePoolByPid(_pid) {
        require(_depositFeeRate <= 10000, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeRate = _depositFeeRate;
        poolInfo[_pid].strategy = _strategy;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
            updateStakingPool();
        }
    }

    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        if (points != 0) {
            points = points.div(3);
            totalAllocPoint = totalAllocPoint.sub(poolInfo[0].allocPoint).add(points);
            poolInfo[0].allocPoint = points;
        }
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public override onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public override {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20Upgradeable lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20Upgradeable newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view override returns (uint256) {
        return _to.sub(_from).mul(bonusMultiplier);
    }

    // View function to see pending CRSSs on frontend.
    function pendingCrss(uint256 _pid, address _user) external view override validatePoolByPid(_pid) returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accCrssPerShare = pool.accCrssPerShare;

        // LP supply
        uint256 lpSupply;
        if (pool.strategy == address(0)) {
            // When pool strategy is zero address, lp supply is the same as balance of masterchef
            lpSupply = pool.lpToken.balanceOf(address(this));
        } else {
            // When pool strategy is not zero address, lp supply come from it
            lpSupply = IStrategy(pool.strategy).sharesTotal();
        }

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 crssReward = multiplier.mul(crssPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accCrssPerShare = accCrssPerShare.add(crssReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accCrssPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Harvest All Rewards pools where user has pending balance at same time!  Be careful of gas spending!
    function massHarvest(uint256[] calldata pools) public {
        for (uint256 i = 0; i < pools.length; i++) {
            if (pools[i] == 0) {
                leaveStaking(0);
            } else {
                withdraw(pools[i], 0);
            }
        }
    }

    function massStakeReward(uint256[] calldata pools) external {
        uint256 oldBalance = ICrssToken(crss).balanceOf(_msgSender());

        massHarvest(pools);

        uint256 newBalance = ICrssToken(crss).balanceOf(_msgSender());
        uint256 amount = newBalance.sub(oldBalance);
        enterStaking(amount);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public override {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function _updatePool(uint256 _pid) internal validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        // LP supply
        uint256 lpSupply;
        if (pool.strategy == address(0)) {
            // When pool strategy is zero address, lp supply is the same as balance of masterchef
            lpSupply = pool.lpToken.balanceOf(address(this));
        } else {
            // When pool strategy is not zero address, lp supply come from it
            lpSupply = IStrategy(pool.strategy).sharesTotal();
        }

        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 crssReward = multiplier.mul(crssPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        uint256 devFee = crssReward.div(10);
        ICrssToken(crss).mint(devaddr, devFee);
        ICrssToken(crss).mint(address(this), crssReward.sub(devFee));
        pool.accCrssPerShare = pool.accCrssPerShare.add(crssReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Calculate Reward from staking, and send it if non-auto compounding, or append it to staking if auto
    function _handleReward(uint256 _pid, bool isAuto) internal validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];

        if (user.amount > 0) {
            // Calculate Reward from staking after the last update
            uint256 pending = user.amount.mul(pool.accCrssPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                if (user.isVest) {
                    // Divide reward into 2, send half to vest
                    uint256 vestReward = pending.div(2);
                    CrssVest memory newVest;
                    newVest.totalAmount = vestReward;
                    newVest.withdrawAmount = 0;
                    newVest.lastWithdraw = block.timestamp;
                    user.vestList.push(newVest);
                    pending -= vestReward;
                } else {
                    // Burn speicifc amount of Reward for Deflationary strategy
                    uint256 burnReward = pending.mul(autoBurnRate).div(FeeMagnifier);
                    ICrssToken(crss).burn(address(this), burnReward);
                    // Calculate Fee for autoCompounding
                    uint256 autoFee = pending.mul(autoFeeRate).div(FeeMagnifier);
                    safeCrssTransfer(devaddr, autoFee);
                    // Reestimate pending amount decreased by burnReward + autoFee
                    pending = pending - burnReward - autoFee;
                }

                // Send Referral Amount to referrer
                payReferralCommission(_msgSender(), pending);

                if (!isAuto) {
                    // if user does not take part in auto compounding, send the reward and make it end
                    safeCrssTransfer(_msgSender(), pending);
                    return;
                } else {
                    // Auto is forbidden in external pool
                    require(pool.strategy == address(0), "external pool");
                    // Approve Crss token to router for swap and add liquidity
                    ICrssToken(crss).approve(router, pending);

                    // Get Pair Contract and Swap Crss to pair tokens and Add Liquidity
                    ICrossPair pair = ICrossPair(address(pool.lpToken));

                    // Get Token addresses of Pair
                    address token0 = pair.token0();
                    address token1 = pair.token1();
                    uint256 token0Amt = pending.div(2);
                    uint256 token1Amt = pending - token0Amt;
                    if (crss != token0) {
                        // Swap half earned to token0
                        uint256 _token0Amt = IERC20Upgradeable(token0).balanceOf(address(this));
                        swapTokenForToken(crss, token0, token0Amt);
                        token0Amt = IERC20Upgradeable(token0).balanceOf(address(this)) - _token0Amt;
                    }
                    if (crss != token1) {
                        // Swap half earned to token1
                        uint256 _token1Amt = IERC20Upgradeable(token1).balanceOf(address(this));
                        swapTokenForToken(crss, token1, token1Amt);
                        token1Amt = IERC20Upgradeable(token1).balanceOf(address(this)) - _token1Amt;
                    }
                    // Add Liquidity
                    if (token0Amt > 0 && token1Amt > 0) {
                        // IERC20Upgradeable(token0).safeIncreaseAllowance(router, token0Amt);
                        IERC20Upgradeable(token1).safeIncreaseAllowance(router, token1Amt);
                        uint256 oldBalance = pool.lpToken.balanceOf(address(this));
                        ICrossRouter(router).addLiquidity(
                            token0,
                            token1,
                            token0Amt,
                            token1Amt,
                            0,
                            0,
                            address(this),
                            block.timestamp + routerDeadlineDuration
                        );
                        {
                            // Calculate newly accumulated LP amount and return it
                            uint256 newBalance = pool.lpToken.balanceOf(address(this));
                            user.amount += newBalance.sub(oldBalance);
                        }
                    }
                }
            }
        }
    }

    // Deposit LP tokens to MasterChef for CRSS allocation.
    function _deposit(uint256 _pid, uint256 _amount) internal validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];

        if (_amount > 0) {
            uint256 oldBalance = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(_msgSender(), address(this), _amount);
            uint256 newBalance = pool.lpToken.balanceOf(address(this));
            _amount = newBalance.sub(oldBalance);

            // If Pool's deposit fee rate is bigger than zero, slice fee and send it to devAddr and treasuryAddr
            if (pool.depositFeeRate > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeRate).div(FeeMagnifier);
                pool.lpToken.safeTransfer(treasuryAddr, depositFee.div(2));
                pool.lpToken.safeTransfer(devaddr, depositFee.div(2));
                _amount = _amount.sub(depositFee);
            }

            // If pool strategy is not zero address, increase deposit amount in strategy contract
            if (pool.strategy != address(0)) {
                pool.lpToken.safeIncreaseAllowance(pool.strategy, _amount);
                _amount = IStrategy(pool.strategy).deposit(_msgSender(), _amount);
            }
            user.amount = user.amount.add(_amount);
        }

        emit Deposit(_msgSender(), _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function _withdraw(uint256 _pid, uint256 _amount) internal validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];

        uint256 stakedAmount;

        if (pool.strategy != address(0)) {
            uint256 lockedTotal = IStrategy(pool.strategy).wantLockedTotal();
            uint256 sharesTotal = IStrategy(pool.strategy).sharesTotal();
            stakedAmount = user.amount.mul(lockedTotal).div(sharesTotal);
        } else {
            stakedAmount = user.amount;
        }

        require(stakedAmount >= _amount, "withdraw: not good");

        uint256 withdrawnAmount;

        if (pool.strategy != address(0)) {
            withdrawnAmount = IStrategy(pool.strategy).withdraw(_msgSender(), _amount);
        } else {
            withdrawnAmount = _amount;
        }

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(_msgSender(), withdrawnAmount);
        }

        emit Withdraw(_msgSender(), _pid, _amount);
    }

    function updatePool(uint256 _pid) public override validatePoolByPid(_pid) {
        _updatePool(_pid);
    }

    // Deposit LP tokens to MasterChef for CRSS allocation.
    function deposit(
        uint256 _pid,
        uint256 _amount,
        bool _isAuto,
        address _referrer,
        bool _isVest
    ) public override validatePoolByPid(_pid) session(SessionType.Deposit) {
        require(_pid != 0, "deposit CRSS by staking");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        if (pool.strategy != address(0)) {
            require(_isAuto == false, "isAuto should be false for external pools");
        }
        if (user.amount > 0) {
            require(user.isAuto == _isAuto, "Cannot change auto compound in progress");
        }
        // User can not change Auto and Vest state while staking
        if (user.amount > 0) {
            require(user.isAuto == _isAuto, "Cannot change auto compound in progress");
            require(user.isVest == _isVest, "Cannot change vesting option in progress");
        }
       
        _updatePool(_pid);

        if (_amount > 0 && crssReferral != address(0) && _referrer != address(0) && _referrer != _msgSender()) {
            ICrssReferral(crssReferral).recordReferral(_msgSender(), _referrer);
        }

        // Get the newly minted LP amount from auto compound: 0 for non-auto account
        _handleReward(_pid, _isAuto);

        _deposit(_pid, _amount);

        // Update user's rewardDebt, and isAuto state
        user.rewardDebt = user.amount.mul(pool.accCrssPerShare).div(1e12);
        user.isAuto = _isAuto;
        user.isVest = _isVest;
    }

    // Turn Staking Reward to Auto Compound
    function earn(uint256 _pid) public override validatePoolByPid(_pid) session(SessionType.Earn) {
        require(_pid != 0, "deposit CRSS by staking");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        
        _updatePool(_pid);

        // Handle reward from staking: 1. Send to user when he is a non-auto user, 2. Turn it into LP and compound it to current pool
        _handleReward(_pid, true);

        _deposit(_pid, 0);
        // Update user's rewardDebt
        user.rewardDebt = user.amount.mul(pool.accCrssPerShare).div(1e12);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public override validatePoolByPid(_pid) session(SessionType.Withdraw) {
        require(_pid != 0, "withdraw CRSS by unstaking");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        require(user.amount >= _amount, "withdraw: not good");
       
        _updatePool(_pid);
               
        // Handle reward from staking: 1. Send to user when he is a non-auto user, 2. Turn it into LP and compound it to current pool
        _handleReward(_pid, user.isAuto);

        _withdraw(_pid, _amount);

        // Update user's rewardDebt, and isAuto state
        user.rewardDebt = user.amount.mul(pool.accCrssPerShare).div(1e12);
        if (user.amount == 0) {
            user.isAuto = false;
        }
    }

    function totalWithDrawableVest(uint256 _pid) public view validatePoolByPid(_pid) returns (uint256) {
        UserInfo storage user = userInfo[_pid][_msgSender()];
        CrssVest[] storage vestList = user.vestList;
        uint256 amount;
        for (uint256 i = 0; i < vestList.length; i++) {
            // Calculate elapsed time
            uint256 elapsed = block.timestamp - vestList[i].lastWithdraw;
            // Calculate how many months elapsed
            uint256 monthElapsed = elapsed / month >= 5 ? 5 : elapsed / month;
            // Calculate how much can be withdrawn according to it vesting period and elapsed period
            uint256 unlockAmount = vestList[i].totalAmount.mul(unlockPerMonth).mul(monthElapsed).div(FeeMagnifier) -
                vestList[i].withdrawAmount;
            amount += unlockAmount;
        }
        return amount;
    }

    // Withdraw Vested Crss
    function withdrawVest(uint256 _pid, uint256 _amount) public override validatePoolByPid(_pid) session(SessionType.WithdrawVest) {
        require(_amount < ICrssToken(crss).balanceOf(address(this)), "Cross: Exceed Total Vested Amount");
        UserInfo storage user = userInfo[_pid][_msgSender()];
        CrssVest[] storage vestList = user.vestList;

        safeCrssTransfer(_msgSender(), _amount);
        for (uint256 i = 0; i < vestList.length; i++) {
            // if requested amount is less than zero, stop executing loop
            if (_amount > 0) {
                // Calculate elapsed time
                uint256 elapsed = block.timestamp - vestList[i].lastWithdraw;
                // Calculate how many months elapsed
                uint256 monthElapsed = elapsed / month >= 5 ? 5 : elapsed / month;
                // Calculate how much can be withdrawn according to it vesting period and elapsed period
                uint256 unlockAmount = vestList[i].totalAmount.mul(unlockPerMonth).mul(monthElapsed).div(FeeMagnifier) -
                    vestList[i].withdrawAmount;
                if (unlockAmount > _amount) {
                    // if unlockAmount is bigger than requested amount, the requested one can be compensated at all
                    vestList[i].withdrawAmount += _amount;
                    _amount = 0;
                } else {
                    // update withdrawAmount in the vest list
                    vestList[i].withdrawAmount += unlockAmount;
                    _amount -= unlockAmount;
                }

                // if all the vested Crss are withdrawn in Current record, delete it
                if (vestList[i].withdrawAmount == vestList[i].totalAmount) {
                    delete vestList[i];
                    i--;
                }
            }
        }

        // If _amount is not equal to zero, which means the total withdrawable amount is smaller than requested amount, revert it
        require(_amount == 0, "Cross: Requested amount exceeds the withdrawable amount");
    }

    // Stake CRSS tokens to MasterChef
    function enterStaking(uint256 _amount) public override session(SessionType.EnterStaking) {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][_msgSender()];
        
        _updatePool(0);

        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accCrssPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeCrssTransfer(_msgSender(), pending);
            }
        }

        if (_amount > 0) {
            uint256 oldBalance = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(_msgSender(), address(this), _amount);
            uint256 newBalance = pool.lpToken.balanceOf(address(this));
            _amount = newBalance.sub(oldBalance);

            user.amount = user.amount.add(_amount);
            user.isAuto = false;
            user.isVest = false;
        }
        user.rewardDebt = user.amount.mul(pool.accCrssPerShare).div(1e12);

        IXCrssToken(xcrss).mint(_msgSender(), _amount);

        emit Deposit(_msgSender(), 0, _amount);
    }

    // Withdraw CRSS tokens from STAKING.
    function leaveStaking(uint256 _amount) public override session(SessionType.LeaveStaking) {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][_msgSender()];
        require(user.amount >= _amount, "withdraw: not good");

        _updatePool(0);

        uint256 pending = user.amount.mul(pool.accCrssPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeCrssTransfer(_msgSender(), pending);
        }

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(_msgSender()), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accCrssPerShare).div(1e12);

        IXCrssToken(xcrss).burn(_msgSender(), _amount);

        emit Withdraw(_msgSender(), 0, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public override validatePoolByPid(_pid) session(SessionType.EmergencyWithdraw) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];

        uint256 amount;
        if (pool.strategy != address(0)) {
            uint256 lockedTotal = IStrategy(pool.strategy).wantLockedTotal();
            uint256 sharesTotal = IStrategy(pool.strategy).sharesTotal();
            amount = user.amount.mul(lockedTotal).div(sharesTotal);
            IStrategy(pool.strategy).withdraw(_msgSender(), amount);
        } else {
            amount = user.amount;
        }

        pool.lpToken.safeTransfer(_msgSender(), amount);
        emit EmergencyWithdraw(_msgSender(), _pid, amount);
        user.amount = 0;
        user.rewardDebt = 0;
        user.isAuto = false;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (crssReferral != address(0) && referralCommissionRate > 0) {
            address referrer = ICrssReferral(crssReferral).getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                ICrssToken(crss).mint(referrer, commissionAmount);
                ICrssReferral(crssReferral).recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }

    // Update the CRSS referral contract address by the owner
    function setCrssReferral(address _crssReferral) external onlyOwner {
        crssReferral = _crssReferral;
        emit SetcrssReferral(_crssReferral);
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint256 _referralCommissionRate) external onlyOwner {
        require(
            _referralCommissionRate <= maximumReferralCommisionRate,
            "invalid referral commission rate basis points"
        );
        referralCommissionRate = _referralCommissionRate;
        emit SetReferralCommissionRate(_referralCommissionRate);
    }

    // Safe crss transfer function, just in case if rounding error causes pool to not have enough CRSS.
    function safeCrssTransfer(address _to, uint256 _amount) internal {
        uint256 crssBal = ICrssToken(crss).balanceOf(address(this));
        if (_amount > crssBal) {
            bool result = ICrssToken(crss).transfer(_to, crssBal);
            require(result == true, "Cross: Transfer Failed");
        } else {
            bool result = ICrssToken(crss).transfer(_to, _amount);
            require(result == true, "Cross: Transfer Failed");
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public override {
        require(_msgSender() == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    function settreasuryAddr(address _treasuryAddr) external {
        require(_msgSender() == treasuryAddr, "settreasuryAddr: FORBIDDEN");
        require(_treasuryAddr != address(0), "settreasuryAddr: ZERO");
        treasuryAddr = _treasuryAddr;
    }

    function setTrustedForwarder(address _trustedForwarder) external onlyOwner {
        require(_trustedForwarder != address(0), "Cross: TrustedForwarder can not be zero address");
        trustedForwarder = _trustedForwarder;
        emit SetTrustedForwarder(_trustedForwarder);
    }

    function swapTokenForToken(
        address token0,
        address token1,
        uint256 amount
    ) internal {
        address[] memory path = new address[](2);
        path[0] = token0;
        path[1] = token1;
        ICrossRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount,
            // Implemented price control via SwapAmountCheck in transaction so that frontrunning is useless
            0,
            path,
            address(this),
            block.timestamp + routerDeadlineDuration
        );
    }
}

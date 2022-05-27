// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../session/SessionRegistrar.sol";
import "../session/SessionManager.sol";
import "./interfaces/ICrssToken.sol";
import "../periphery/interfaces/ICrossRouter.sol";
import "../core/interfaces/ICrossFactory.sol";
import "../core/interfaces/ICrossPair.sol";
import "../libraries/math/SafeMath.sol";

import "hardhat/console.sol";

// CrssToken with Governance.
contract CrssToken is ICrssToken, OwnableUpgradeable, SessionRegistrar, ISessionFeeOffice, SessionManager {
    using SafeMath for uint256;

    string private constant _name = "Crosswise Token";
    string private constant _symbol = "CRSS";
    uint8 private constant _decimals = 18;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private __totalSupply;
    mapping(address => uint256) private __balances;

    string private constant stringForbidden = "Cross: FORBIDDEN";

    address public override router;
    address public override farm;
    address public override crssBnbPair;
    address public override crssBusdPair;

    uint256 public constant override maxSupply = 50 * 1e6 * 10**_decimals;

    // ----------------------------- Transfer control attributes -------------------------
    struct TransferAmountOriginSession {
        uint256 sent;
        uint256 received;
        uint256 originSession;
    }
    mapping(address => TransferAmountOriginSession) transferAmountAccumulatedOS;
    uint256 public override maxTransferAmountRate; // rate based on FeeMagnifier.
    uint256 public maxTransferAmount;
    address[] transferUsers;

    struct Pair {
        address token0;
        address token1;
    }
    mapping(address => Pair) public pairs;

    uint256 public liquifyThreshold;

    mapping(address => address) internal __delegates;

    /// @notice A checkpoint for marking number of votes from a given block
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    /// @notice A record of votes checkpoints for each account, by index
    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;

    /// @notice The number of checkpoints for each account
    mapping(address => uint32) public numCheckpoints;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @notice The EIP-712 typehash for the delegation struct used by the contract
    bytes32 public constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    mapping(address => uint256) public nonces;

    /// @notice An event thats emitted when an account changes its delegate
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    /// @notice An event thats emitted when a delegate account's vote balance changes
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);

    /// @notice An event thats emitted when swap and liquify happens
    event SwapAndLiquify(uint256 crssPart, uint256 crssForEthPart, uint256 ethPart, uint256 liquidity);

    receive() external payable {}


    function initialize(FeeStores memory _feeStores, address _router, uint256 _liquifyThreshold) external initializer {
        require(_msgSender() == ICrossRouter(_router).getOwner(), stringForbidden);
        __Ownable_init();

        sessionRegistrar = ISessionRegistrar(address(this));
        sessionFeeOffice = ISessionFeeOffice(address(this));

        FeeStores memory initialFeeStores = _feeStores;
        FeeRates[NumberSessionTypes] memory initialFeeRatesArray = [
            // Fee: (Developer, Buyback, Liquidity)
            FeeRates(0, 0, 0), // None
            FeeRates(40, 30, 30), // Transfer: 0.04%, 0.03%, 0.03%
            FeeRates(40, 30, 30), // Swap:
            FeeRates(0, 0, 0), // AddLiquidity
            FeeRates(0, 0, 0), // RemoveLiquidity
            FeeRates(0, 0, 0), // EmergencyWithdraw
            FeeRates(0, 0, 0), // Deposit
            FeeRates(0, 0, 0), // Withdraw
            FeeRates(0, 0, 0), // WithdrawVest
            FeeRates(0, 0, 0), // EnterStaking
            FeeRates(0, 0, 0), // LeaveStaking
            FeeRates(0, 0, 0) // Earn
        ];

        ISessionManager(address(this)).initializeFees(initialFeeStores, initialFeeRatesArray);
        ISessionManager(router).initializeFees(initialFeeStores, initialFeeRatesArray);
        ISessionManager(farm).initializeFees(initialFeeStores, initialFeeRatesArray);

        router = _router;

        liquifyThreshold = _liquifyThreshold;
        maxTransferAmountRate = 50;

        // Mint 1e6 Crss to the caller for testing - MUST BE REMOVED WHEN DEPLOY
        __mint(_msgSender(), 1e6 * 10 ** _decimals);
        __moveDelegates(address(0), __delegates[_msgSender()], 1e6 * 10 ** _decimals);
    }

    modifier OnlyGovernance override virtual {
        require(msg.sender == address(this), stringForbidden);
        _;
    }

    function getOwner() external view override returns (address) {
        return owner();
    }

    function informOfPair(address pair, address token0, address token1) public override virtual {
        require(msg.sender == router, stringForbidden);
        pairs[pair] = Pair(token0, token1);
    }

    function setRouter(address _router) external override onlyOwner {
        require(_msgSender() == ICrossRouter(_router).getOwner(), stringForbidden);
        router = _router;
        crssBnbPair = ICrossFactory(ICrossRouter(router).factory()).createPair(
            address(this),
            ICrossRouter(router).WETH()
        );
    }

    function setFarm(address crssFarm) external override onlyOwner {
        farm = crssFarm;
    }

    function setFeeRatesManagers(uint256 _sessionEnum, FeeRates memory _feeRates) public virtual onlyOwner {
        ISessionManager(address(this)).setFeeRates(_sessionEnum, _feeRates);
        ISessionManager(router).setFeeRates(_sessionEnum, _feeRates);
        ISessionManager(farm).setFeeRates(_sessionEnum, _feeRates);
    }

    function setFeeStoresManagers(FeeStores memory _feeStores) public virtual onlyOwner {
        ISessionManager(address(this)).setFeeStores(_feeStores);
        ISessionManager(router).setFeeStores(_feeStores);
        ISessionManager(farm).setFeeStores(_feeStores);
    }


    function setLiquifyThreshold(uint256 _liquifyThreshold) public onlyOwner {
        liquifyThreshold = _liquifyThreshold;
    }

    modifier dsManagersOnly override virtual {
        address msgSender = _msgSender();
        require(msgSender == router || msgSender == farm || msgSender == address(this), stringForbidden);
        _;
    }

    function name() public view virtual returns (string memory) {
        return _name;
    }

    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view virtual override returns (uint256) {
        return __totalSupply;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return __balances[account];
    }

    function mint(address _to, uint256 _amount) public override {
        require(msg.sender == farm, stringForbidden);
        _mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) public override {
        require(msg.sender == farm, stringForbidden);
        _burn(_from, _amount);
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, _msgSender(), currentAllowance - amount);
        _transfer(sender, recipient, amount); // No guarentee it doesn't make a change to _allowances. Revert if it fails.

        return true;
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        _approve(_msgSender(), spender, currentAllowance - subtractedValue);
        return true;
    }

    function _mint(address to, uint256 amount) internal virtual {
        require(__totalSupply + amount <= maxSupply, "ERC20: Exceed Max Supply");
        require(_msgSender() == farm, stringForbidden);
        __mint(to, amount);
        __moveDelegates(address(0), __delegates[to], amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(_msgSender() == farm, stringForbidden);
        __burn(account, amount);
        __moveDelegates(__delegates[account], __delegates[address(0)], amount);
    }

    function _bury(address account, uint256 amount) internal virtual {
        __bury(account, amount);
        __moveDelegates(__delegates[account], __delegates[address(0)], amount);
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual session(SessionType.Transfer) {

        _limitTransferOriginSession(sender, recipient, amount);

        if (dsParams.isOriginAction) { // transfer call coming from external actors.
            FeeRates memory rates;
            if (pairs[recipient].token0 != address(0)) { // An injection detected!
                rates = FeeRates( FeeMagnifier, 0, 0 );
            } else {
                rates = feeRatesArray[uint256(SessionType.Transfer)];
            }
            amount -= _payFee(sender, amount, rates); // No transfer recursion happens here.
        }

        if (amount > 0) {
            __transfer(sender, recipient, amount);
            __moveDelegates(__delegates[sender], __delegates[recipient], amount);
        }
    }

    function payFeeImplementation(address account, uint256 principal, FeeRates memory rates ) public override virtual returns (uint256 feesPaid) {
        
        if (principal != 0) {
            uint256 developerFee; uint256 buybackFee; uint256 liquidityFee;
            if (rates.developer != 0) {
                developerFee = principal * rates.developer / FeeMagnifier;
                __transfer(account, feeStores.developer, developerFee);
                __moveDelegates(__delegates[account], __delegates[feeStores.developer], developerFee);
                feesPaid += developerFee;
            }
            if (rates.buyback != 0) {
                buybackFee = principal * rates.buyback / FeeMagnifier;
                __transfer(account, feeStores.buyback, buybackFee);
                __moveDelegates(__delegates[account], __delegates[feeStores.buyback], buybackFee);
                feesPaid += buybackFee;
            }
            if (rates.liquidity != 0) {
                liquidityFee = principal * rates.liquidity / FeeMagnifier;
                __transfer(account, feeStores.liquidity, liquidityFee);
                __moveDelegates(__delegates[account], __delegates[feeStores.liquidity], liquidityFee); 

                uint256 crssOnCrssBnbPair = ICrossRouter(router).getReserveOnETHPair(address(this));
                uint256 liquidityFeeAccumulated = __balances[feeStores.liquidity];
                if ( liquidityFeeAccumulated * 500 >= crssOnCrssBnbPair ) _liquifyLiquidityFees();
                feesPaid += liquidityFee;
            }
        }
    }

    function _limitTransferOriginSession(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        if ( ( sender == owner() || sender == address(this) ) && pairs[recipient].token0 != address(0) ) {
            require( pairs[recipient].token0 == address(this) || pairs[recipient].token1 == address(this), stringForbidden );
        } else{
            if (dsParams.originSession != dsParams.lastOriginSession) {
                maxTransferAmount = __totalSupply.mul(maxTransferAmountRate).div(FeeMagnifier);
                if (transferUsers.length > 2000) _freeUpTransferUsersSpace();
            }

            _initailizeTransferUserOS(sender);
            transferAmountAccumulatedOS[sender].sent += amount;

            _initailizeTransferUserOS(recipient);
            transferAmountAccumulatedOS[recipient].received += amount;

            require(transferAmountAccumulatedOS[sender].sent.abs(transferAmountAccumulatedOS[sender].received) < maxTransferAmount
            && transferAmountAccumulatedOS[recipient].sent.abs(transferAmountAccumulatedOS[recipient].received) < maxTransferAmount, 
            "CrssToken: Exceed MaxTransferAmount");
        }
    }

    function _initailizeTransferUserOS(address user) internal virtual {
        if( transferAmountAccumulatedOS[user].originSession == 0 ) transferUsers.push(user);
        if (transferAmountAccumulatedOS[user].originSession != dsParams.originSession) {
            transferAmountAccumulatedOS[user].sent = 0;
            transferAmountAccumulatedOS[user].received = 0;
            transferAmountAccumulatedOS[user].originSession = dsParams.originSession;
        }
    }

    function _freeUpTransferUsersSpace() internal virtual {
        uint256 length = transferUsers.length;
        for( uint256 i = 0; i < length; i ++) {
            address user = transferUsers[i];
            transferAmountAccumulatedOS[user].sent = 0;
            transferAmountAccumulatedOS[user].received = 0;
            transferAmountAccumulatedOS[user].originSession = 0;
        }
        delete transferUsers;
        transferUsers = new address[](0);
    }

    function _approve(
        address _owner,
        address _spender,
        uint256 _amount
    ) internal virtual {
        require(_owner != address(0), "ERC20: approve from the zero address");
        require(_spender != address(0), "ERC20: approve to the zero address");

        _allowances[_owner][_spender] = _amount;
        emit Approval(_owner, _spender, _amount);
    }

    function __mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        __beforeTokenTransfer(address(0), account, amount);
        __totalSupply += amount;
        __balances[account] += amount;
        __afterTokenTransfer(address(0), account, amount);

        emit Transfer(address(0), account, amount);
    }

    function __burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");
        uint256 accountBalance = __balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");

        __beforeTokenTransfer(account, address(0), amount);
        __balances[account] = accountBalance - amount;
        __totalSupply -= amount;
        __afterTokenTransfer(account, address(0), amount);

        emit Transfer(account, address(0), amount);
    }

    function __bury(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: bury from the zero address");
        uint256 accountBalance = __balances[account];
        require(accountBalance >= amount, "ERC20: bury amount exceeds balance");

        __beforeTokenTransfer(account, address(0), amount);
        __balances[account] = accountBalance - amount;
        __afterTokenTransfer(account, address(0), amount);

        emit Transfer(account, address(0), amount);    
    }

    function __transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        uint256 senderBalance = __balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");

        __beforeTokenTransfer(sender, recipient, amount);
        __balances[sender] = senderBalance - amount;
        __balances[recipient] += amount;
        __afterTokenTransfer(sender, recipient, amount);

        emit Transfer(sender, recipient, amount);
    }

    function __beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    function __afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    function _liquifyLiquidityFees() internal {
        // Assum: this->Pair is free of TransferControl.

        uint256 liquidityFeeAccumulated = __balances[feeStores.liquidity];
        __transfer(feeStores.liquidity, address(this), liquidityFeeAccumulated);

        uint256 crssPart = liquidityFeeAccumulated.div(2);
        uint256 crssForEthPart = liquidityFeeAccumulated.sub(crssPart);

        uint256 initialBalance = address(this).balance;
        _swapForETH(crssForEthPart); // 
        uint256 ethPart = address(this).balance.sub(initialBalance);
        uint256 liquidity = _addLiquidity(crssPart, ethPart);
        
        emit SwapAndLiquify(crssPart, crssForEthPart, ethPart, liquidity);
    }

    function _swapForETH(uint256 tokenAmount) internal {
        // generate the uniswap pair path of token -> WBNB
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = ICrossRouter(router).WETH();

        _approve(address(this), address(router), tokenAmount);
        ICrossRouter(router).swapExactTokensForETH(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) internal returns (uint256 liquidity) {
        _approve(address(this), address(router), tokenAmount);

        (, , liquidity) = ICrossRouter(router).addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            // Implemented price control via SwapAmountCheck in transaction so that frontrunning is useless
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    function __delegate(address delegator, address delegatee) internal {
        address currentDelegate = __delegates[delegator];
        uint256 delegatorBalance = balanceOf(delegator); // balance of underlying CRSSs (not scaled);
        __delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        __moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function delegates(address delegator) external view returns (address) {
        return __delegates[delegator];
    }

    function delegate(address delegatee) external {
        return __delegate(_msgSender(), delegatee);
    }

    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name())), getChainId(), address(this))
        );

        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "CRSS::delegateBySig: invalid signature");
        require(nonce == nonces[signatory]++, "CRSS::delegateBySig: invalid nonce");
        require(block.timestamp <= expiry, "CRSS::delegateBySig: signature expired");
        return __delegate(signatory, delegatee);
    }

    function getCurrentVotes(address account) external view returns (uint256) {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint256) {
        require(blockNumber < block.number, "CRSS::getPriorVotes: not yet determined");

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    function safe32(uint256 n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function getChainId() internal view returns (uint256) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }

    function __moveDelegates(
        address srcRep,
        address dstRep,
        uint256 amount
    ) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                // decrease old representative
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint256 srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld.sub(amount);
                __writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                // increase new representative
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint256 dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld.add(amount);
                __writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function __writeCheckpoint(
        address delegatee,
        uint32 nCheckpoints,
        uint256 oldVotes,
        uint256 newVotes
    ) internal {
        uint32 blockNumber = safe32(block.number, "CRSS::__writeCheckpoint: block number exceeds 32 bits");

        if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }
}

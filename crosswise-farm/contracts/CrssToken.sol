// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

import "./libs/Context.sol";
import "./libs/IBEP20.sol";
import "./libs/Ownable.sol";
import './interface/ICrosswiseRouter02.sol';
import './interface/ICrosswiseFactory.sol';

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

// CrssToken with Governance.
contract CrssToken is IBEP20, Ownable {

    using SafeMath for uint256;
    using Address for address;

    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;
    uint8 private _decimals;

    uint256 public constant maxSupply = 50000000000000000000000000;
    uint256 public devFee;
    uint256 public liquidityFee;
    uint256 public buybackFee;

    uint256 public maxTransferAmountRate = 50;

    address public devTo;
    address public buybackTo;
    address public constant burnAddress = 0x000000000000000000000000000000000000dEaD;

    bool inSwapAndLiquify;
    bool public swapAndLiquifyEnabled = true;

    ICrosswiseRouter02 public crosswiseRouter;
    address public crssBnbPair;
    
    IBEP20 public oldCrss;
    IBEP20 public oldCrss1;

    mapping(address => bool) private _excludedFromAntiWhale;
    mapping(address => bool) whitelist;

    event MinTokensBeforeSwapUpdated(uint256 minTokensBeforeSwap);
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensintoLiquidity
    );
    event WhitelistedTransfer(address indexed from, address indexed to, uint256 total);
    event SetWhiteList(address indexed addr, bool status);
    event Init_router(address indexed router);
    event SetMaxTransferAmountRate(uint256 maxTransferAmountRate);
    event ClaimV1Token(address indexed user, uint256 balance);
    event Mint(address indexed to, uint256 amount);
    event SetExcludedFromAntiWhale(address indexed account, bool excluded);

    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    modifier antiWhale(address sender, address recipient, uint256 amount) {
        if (maxTransferAmount() > 0) {
            if (
                _excludedFromAntiWhale[sender] == false
                && _excludedFromAntiWhale[recipient] == false
            ) {
                require(amount <= maxTransferAmount(), "CRSS::antiWhale: Transfer amount exceeds the maxTransferAmount");
            }
        }
        _;
    }

    //to recieve ETH from crosswiseRouter when swaping
    receive() external payable {}

    constructor(
        address _devTo,
        address _buybackTo,
        IBEP20 _oldCrss,
        IBEP20 _oldCrss1
    ) public {
        require(_devTo != address(0), 'CrssToken: dev address is zero');
        require(_buybackTo != address(0), 'CrssToken: buyback address is zero');
        require(address(_oldCrss) != address(0), 'CrssToken: old crss address is zero');
        require(address(_oldCrss1) != address(0), 'CrssToken: old crss address is zero');

        _name = 'Crosswise V1.1 Token';
        _symbol = 'CRSS';
        _decimals = 18;

        devTo = _devTo;
        buybackTo = _buybackTo;

        oldCrss = _oldCrss;
        oldCrss1 = _oldCrss1;

        devFee = 4; // 0.04%
        liquidityFee = 3; // 0.03%
        buybackFee = 3; // 0.03%

        _excludedFromAntiWhale[msg.sender] = true;

        // AUDIT : CTC-08 | Anti-whale Addresses
        _excludedFromAntiWhale[burnAddress] = true;
        _excludedFromAntiWhale[address(this)] = true;
    }
    
    function init_router(address router) public onlyOwner {
        ICrosswiseRouter02 _crosswiseRouter = ICrosswiseRouter02(router);
        // Create a uniswap pair for this new token
        crssBnbPair = ICrosswiseFactory(_crosswiseRouter.factory())
        .createPair(address(this), _crosswiseRouter.WBNB());

        // set the rest of the contract variables
        crosswiseRouter = _crosswiseRouter;
        emit Init_router(router);
    }
    
    function getOwner() external view returns (address) {
        return owner();
    }
    function name() public view returns (string memory) {
        return _name;
    }
    function decimals() public view returns (uint8) {
        return _decimals;
    }
    function symbol() public view returns (string memory) {
        return _symbol;
    }
    function totalSupply() public override view returns (uint256) {
        return _totalSupply;
    }
    function balanceOf(address account) public override view returns (uint256) {
        return _balances[account];
    }
    function allowance(address owner, address spender) public override view returns (uint256) {
        return _allowances[owner][spender];
    }
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }
    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }
    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].sub(subtractedValue, 'BEP20: decreased allowance below zero')
        );
        return true;
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), 'BEP20: mint to the zero address');
        if(_totalSupply + amount > maxSupply) {
            amount = maxSupply.sub(_totalSupply);
        }
        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal {
        require(owner != address(0), 'BEP20: approve from the zero address');
        require(spender != address(0), 'BEP20: approve to the zero address');

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    
    function transfer(address recipient, uint256 amount) public override antiWhale(_msgSender(), recipient, amount) returns (bool) {
        require(recipient != address(0), "BEP20: transfer to the zero address");
        require(balanceOf(_msgSender()) >= amount, "BEP20: transfer amount exceeds balance");

        if (whitelist[recipient] || whitelist[_msgSender()]) {
            _transfer(_msgSender(), recipient, amount);
            _moveDelegates(_delegates[_msgSender()], _delegates[recipient], amount);
            emit WhitelistedTransfer(_msgSender(), recipient, amount);
        } else {
            uint256 devAmount = amount.mul(devFee).div(10000);
            uint256 buybackAmount = amount.mul(buybackFee).div(10000);
            uint256 transferAmount = amount.sub(devAmount).sub(buybackAmount);

            if (
                !inSwapAndLiquify &&
                _msgSender() != crssBnbPair &&
                swapAndLiquifyEnabled
            ) {
                uint256 liquidityAmount = amount.mul(liquidityFee).div(10000);
                transferAmount = transferAmount.sub(liquidityAmount);

                // AUDIT : CTC-10 | Liquidity Fee Calculation
                amount = amount.sub(liquidityAmount);

                _transfer(_msgSender(), address(this), liquidityAmount);
                
                // AUDIT : CTC-09 | Voting Power Not Moved Along With Liquify
                _moveDelegates(_delegates[_msgSender()], _delegates[address(this)], liquidityAmount);
                swapAndLiquify();
            }

            if(recipient == crssBnbPair) {
                _transfer(_msgSender(), recipient, amount);    
                _moveDelegates(_delegates[_msgSender()], _delegates[recipient], amount);
            }
            else {
                _transfer(_msgSender(), recipient, transferAmount);
                _moveDelegates(_delegates[_msgSender()], _delegates[recipient], transferAmount);

                _transfer(_msgSender(), devTo, devAmount);
                _moveDelegates(_delegates[_msgSender()], _delegates[devTo], devAmount);

                _transfer(_msgSender(), buybackTo, buybackAmount);
                _moveDelegates(_delegates[_msgSender()], _delegates[buybackTo], buybackAmount);
            }
        }

        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override antiWhale(sender, recipient, amount) returns (bool) {
        require(sender != address(0), "BEP20: transfer to the zero address");
        require(recipient != address(0), "BEP20: transfer to the zero address");

        if (whitelist[recipient] || whitelist[sender]) {
            _transfer(sender, recipient, amount);
            _moveDelegates(_delegates[sender], _delegates[recipient], amount);
            emit WhitelistedTransfer(sender, recipient, amount);
        } else {

            uint256 transferAmount = amount.mul(10000 - devFee - buybackFee).div(10000);

            if (
                !inSwapAndLiquify &&
                sender != crssBnbPair &&
                swapAndLiquifyEnabled
            ) {
                uint256 liquidityAmount = amount.mul(liquidityFee).div(10000);
                transferAmount = transferAmount.sub(liquidityAmount);

                // AUDIT : CTC-10 | Liquidity Fee Calculation
                amount = amount.sub(liquidityAmount);

                _transfer(sender, address(this), liquidityAmount);

                // AUDIT : CTC-09 | Voting Power Not Moved Along With Liquify
                _moveDelegates(_delegates[sender], _delegates[address(this)], liquidityAmount);
                swapAndLiquify();
            }
            if(recipient == crssBnbPair) {
                _transfer(sender, recipient, amount);
                _moveDelegates(_delegates[sender], _delegates[recipient], amount);
            }
            else {
                _transfer(sender, recipient, transferAmount);
                _moveDelegates(_delegates[sender], _delegates[recipient], transferAmount);

                _transfer(sender, devTo, amount.mul(devFee).div(10000));
                _moveDelegates(_delegates[sender], _delegates[devTo], amount.mul(devFee).div(10000));

                _transfer(sender, buybackTo, amount.mul(buybackFee).div(10000));
                _moveDelegates(_delegates[sender], _delegates[buybackTo], amount.mul(buybackFee).div(10000));
            }
        }
        _approve(
            sender,
            _msgSender(),
            allowance(sender,_msgSender()).sub(amount, "BEP20: transfer amount exceeds allowance")
        );
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), 'BEP20: transfer from the zero address');
        require(recipient != address(0), 'BEP20: transfer to the zero address');


        _balances[sender] = _balances[sender].sub(amount, 'BEP20: transfer amount exceeds balance');
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }


    function claimV1Token() external {
        // AUDIT : CTC-07 | Discussion on claimV1Token() Function
        // DEV : We get balance of msg.sender before transferFrom because of the fees.
        uint256 balance = oldCrss.balanceOf(_msgSender());
        uint256 balance1 = oldCrss1.balanceOf(_msgSender());
        uint256 mintBalance = balance.add(balance1);

        // AUDIT : CTC-01 | Return value not handled
        bool success = oldCrss.transferFrom(_msgSender(), burnAddress, balance);
        require(success, "Trasnfer token Failed");
        bool success1 = oldCrss1.transferFrom(_msgSender(), burnAddress, balance1);
        require(success1, "Trasnfer token Failed");
        
        _mint(_msgSender(), mintBalance);
        
        // AUDIT : CTC-06 | Does not move delegates while mint token
        _moveDelegates(address(0), _delegates[_msgSender()], mintBalance);

        // AUDIT : CTC-03 | Missing Emit Events
        emit ClaimV1Token(_msgSender(), mintBalance);
    }

    function setSwapAndLiquifyEnabled(bool _enabled) public onlyOwner {
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

     function setMaxTransferAmountRate(uint256 _maxTransferAmountRate) public onlyOwner {
        require(_maxTransferAmountRate <= 10000, "CrssToken.setMaxTransferAmountRate: Max transfer amount rate must not exceed the maximum rate.");
        maxTransferAmountRate = _maxTransferAmountRate;
        emit SetMaxTransferAmountRate(_maxTransferAmountRate);
    }

    function setWhiteList(address _addr, bool _status) external onlyOwner {
        require(_addr != address(0), "CrssToken.setWhiteList: Zero Address");
        whitelist[_addr] = _status;
        emit SetWhiteList(_addr, _status);
    }

    function swapAndLiquify() private lockTheSwap {
        uint256 contractTokenBalance = balanceOf(address(this));
        // split the contract balance into halves
        uint256 maxTransferAmount = maxTransferAmount();
        contractTokenBalance = contractTokenBalance > maxTransferAmount ? maxTransferAmount : contractTokenBalance;

        uint256 half = contractTokenBalance.div(2);
        uint256 otherHalf = contractTokenBalance.sub(half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        swapTokensForBNB(half); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to uniswap
        addLiquidity(otherHalf, newBalance);
        
        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function swapTokensForBNB(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> WBNB
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = crosswiseRouter.WBNB();

        _approve(address(this), address(crosswiseRouter), tokenAmount);

        // make the swap
        crosswiseRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(crosswiseRouter), tokenAmount);

        // add the liquidity
        (,,uint liquidity) = crosswiseRouter.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(this),
            block.timestamp
        );

        // AUDIT : CTC-01 | Return value not handled
        require(liquidity > 0, "Add liquidity failed");
    }

    /// @dev Creates `_amount` token to `_to`. Must only be called by the owner (MasterChef).
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
        _moveDelegates(address(0), _delegates[_to], _amount);

        // AUDIT : CTC-03 | Missing Emit Events
        emit Mint(_to, _amount);
    }
    // Copied and modified from YAM code:
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernanceStorage.sol
    // https://github.com/yam-finance/yam-protocol/blob/master/contracts/token/YAMGovernance.sol
    // Which is copied and modified from COMPOUND:
    // https://github.com/compound-finance/compound-protocol/blob/master/contracts/Governance/Comp.sol

    /// @dev A record of each accounts delegate
    mapping (address => address) internal _delegates;

    /// @dev A checkpoint for marking number of votes from a given block
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    /// @dev A record of votes checkpoints for each account, by index
    mapping (address => mapping (uint32 => Checkpoint)) public checkpoints;

    /// @dev The number of checkpoints for each account
    mapping (address => uint32) public numCheckpoints;

    /// @dev The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @dev The EIP-712 typehash for the delegation struct used by the contract
    bytes32 public constant DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @dev A record of states for signing / validating signatures
    mapping (address => uint) public nonces;

      /// @dev An event thats emitted when an account changes its delegate
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    /// @dev An event thats emitted when a delegate account's vote balance changes
    event DelegateVotesChanged(address indexed delegate, uint previousBalance, uint newBalance);

    /**
     * @dev Delegate votes from `msg.sender` to `delegatee`
     * @param delegator The address to get delegatee for
     */
    function delegates(address delegator)
        external
        view
        returns (address)
    {
        return _delegates[delegator];
    }

   /**
    * @dev Delegate votes from `msg.sender` to `delegatee`
    * @param delegatee The address to delegate votes to
    */
    function delegate(address delegatee) external {
        return _delegate(_msgSender(), delegatee);
    }

    /**
     * @dev Delegates votes from signatory to `delegatee`
     * @param delegatee The address to delegate votes to
     * @param nonce The contract state required to match the signature
     * @param expiry The time at which to expire the signature
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     */
    function delegateBySig(
        address delegatee,
        uint nonce,
        uint expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(name())),
                getChainId(),
                address(this)
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                DELEGATION_TYPEHASH,
                delegatee,
                nonce,
                expiry
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                structHash
            )
        );

        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "CRSS::delegateBySig: invalid signature");
        require(nonce == nonces[signatory]++, "CRSS::delegateBySig: invalid nonce");
        require(now <= expiry, "CRSS::delegateBySig: signature expired");
        return _delegate(signatory, delegatee);
    }

    /**
     * @dev Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account)
        external
        view
        returns (uint256)
    {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @dev Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint blockNumber)
        external
        view
        returns (uint256)
    {
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

    function _delegate(address delegator, address delegatee)
        internal
    {
        address currentDelegate = _delegates[delegator];
        uint256 delegatorBalance = balanceOf(delegator); // balance of underlying CRSSs (not scaled);
        _delegates[delegator] = delegatee;

        emit DelegateChanged(delegator, currentDelegate, delegatee);

        _moveDelegates(currentDelegate, delegatee, delegatorBalance);
    }

    function _moveDelegates(address srcRep, address dstRep, uint256 amount) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                // decrease old representative
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint256 srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld.sub(amount);
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                // increase new representative
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint256 dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld.add(amount);
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(
        address delegatee,
        uint32 nCheckpoints,
        uint256 oldVotes,
        uint256 newVotes
    )
        internal
    {
        uint32 blockNumber = safe32(block.number, "CRSS::_writeCheckpoint: block number exceeds 32 bits");

        if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints[delegatee][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, newVotes);
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }

        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function maxTransferAmount() public view returns (uint256) {
        return totalSupply().mul(maxTransferAmountRate).div(10000);
    }

    function isExcludedFromAntiWhale(address _account) public view returns (bool) {
        return _excludedFromAntiWhale[_account];
    }

    function setExcludedFromAntiWhale(address _account, bool _excluded) public onlyOwner {
        _excludedFromAntiWhale[_account] = _excluded;
        // AUDIT : CTC-03 | Missing Emit Events
        emit SetExcludedFromAntiWhale(_account, _excluded);
    }

    function safe32(uint n, string memory errorMessage) internal pure returns (uint32) {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function getChainId() internal pure returns (uint) {
        uint256 chainId;
        assembly { chainId := chainid() }
        return chainId;
    }
}
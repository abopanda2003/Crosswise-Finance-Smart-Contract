// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../session/SessionManager.sol";
import "../libraries/utils/TransferHelper.sol";
import "../libraries/CrossLibrary.sol";
import "../libraries/math/SafeMath.sol";
import "../libraries/utils/ChainLinkLib.sol";
import "../core/interfaces/ICrossFactory.sol";
import "../farm/interfaces/ICrssToken.sol";
import "./interfaces/ICrossRouter.sol";
import "./interfaces/IWETH.sol";

contract CrossRouter is ICrossRouter, Ownable, SessionManager {
    using SafeMath for uint256;
    //using ChainLink;

    address public immutable override factory;
    address public immutable override WETH;
    address public crssContract;

    struct Pair {
        address token0;
        address token1;
    }
    mapping(address => Pair) public pairs;

    // ----------------------------- Price control attributes -------------------------

    // i-th: excludes most less likely prices, total (i)% on the two sides. i in [1, 10] // based on FeeMagnifier.
    //int32[] public zValuePerRuleOutPercent = [int32(257600), 232600, 217000, 205300, 195900, 188000, 181200, 175100, 169500, 164400];
    //int32[] public zValuePerRuleOutPercent = [int32(257600), 232600, 217000, 205300, 195900, 188000, 181200, 175100, 169500, 164400];
    //.99498, .98994, .98488, .97979, .97467, .96953, .96436, .95916, .95393, .94868, 
    int32[] public zValuePerRuleOutPercent = [int32(280600), 257400, 242900, 232100, 223700, 216300, 210100, 204500, 199500, 194800];

    mapping(address => CLFeed) public chainlinkFeeds;

    struct PairPriceOriginSession {
        int256 price;
        uint256 originSession;
    }
    mapping(address => PairPriceOriginSession) initialPairPrices;
    int256 public originSessionPriceChangeLimit = 200; // rate based on FeeMagnifier.

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "CrossRouter: EXPIRED");
        _;
    }

    constructor(address _factory, address _WETH) {
        factory = _factory; 
        WETH = _WETH;
        ChainLink.initializeBnbMainNetCLFeeds(chainlinkFeeds);
        //ChainLink.initializeBnbTestNetCLFeeds(chainlinkFeeds);
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    function getOwner() external view override returns (address) {
        return owner();
    }

    function informOfPair(address pair, address token0, address token1) public override virtual {
        require(msg.sender == factory, "Cross: FORBIDDEN");
        pairs[pair] = Pair(token0, token1);
        ICrssToken(crssContract).informOfPair(pair, token0, token1);
    }

    function getReserveOnETHPair(address token) external view override virtual returns (uint256 reserve) {
        (uint256 reserve, ) = CrossLibrary.getReserves(factory, token, WETH);
    }

    modifier OnlyGovernance override virtual {
        require(msg.sender == crssContract, "Cross: FORBIDDEN");
        _;
    }

    function setCrssContract(address _crssContract) external override {
        require(msg.sender == ICrossFactory(factory).feeToSetter(), "Cross: FORBIDDEN");
        crssContract = _crssContract;

        sessionRegistrar = ISessionRegistrar(_crssContract);
        sessionFeeOffice = ISessionFeeOffice(_crssContract);
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity( // Get amounts to transfer to the pair fee of fees.
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal virtual returns (uint256 amountA, uint256 amountB) {

        FeeRates memory rates = feeRatesArray[uint256(dsParams.sessionType)];
        if (dsParams.isOriginAction) { // Transform user-available amount to can-arrive-at-pair amount.
            if (tokenA == crssContract) {
                amountADesired = _getInnerFeeRemoved(amountADesired, rates);
            } else if (tokenB == crssContract) {
                amountBDesired = _getInnerFeeRemoved(amountBDesired, rates);
            }
        }

        // Tansfor can-arrive-at-pair amount to must-arrive-at-pair amount.
        if (ICrossFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            address pair = ICrossFactory(factory).createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB) = CrossLibrary.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = CrossLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "CrossRouter: INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = CrossLibrary.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, "CrossRouter: INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }

        if (dsParams.isOriginAction) { // Transform must-arrive-at-pair amount to must-depart-from-user amount, then payFee.
            if (tokenA == crssContract) {
                amountA = _getOuterFeeAdded(amountA, rates);
                amountA -= _payFee(msg.sender, amountA, rates);
            } else if (tokenB == crssContract) {
                amountB = _getOuterFeeAdded(amountB, rates);
                amountB -= _payFee(msg.sender, amountB, rates);
            }
        }

        require(amountA >= amountAMin, "CrossRouter: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "CrossRouter: INSUFFICIENT_B_AMOUNT");
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        virtual
        override
        ensure(deadline)
        session(SessionType.AddLiquidity)
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);

        address pair = CrossLibrary.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = ICrossPair(pair).mint(to);
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        ensure(deadline)
        session(SessionType.AddLiquidity)
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        )
    {
        address pair = CrossLibrary.pairFor(factory, token, WETH);
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );

        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = ICrossPair(pair).mint(to);
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** ADD LIQUIDITY SUPPORTING FEE ****
    function addLiquiditySupportingFeeOnTransferTokens(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        virtual
        override
        ensure(deadline)
        session(SessionType.AddLiquidity)
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {

        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);

        address pair = CrossLibrary.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = ICrossPair(pair).mint(to);
    }

    function addLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        ensure(deadline)
        session(SessionType.AddLiquidity)
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        )
    {
        (amountToken, amountETH) = _addLiquidity(token, WETH, amountTokenDesired, msg.value, amountTokenMin, amountETHMin);

        address pair = CrossLibrary.pairFor(factory, token, WETH);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = ICrossPair(pair).mint(to);
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** REMOVE LIQUIDITY ****
    function _removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to
    ) internal virtual returns (uint256 amountA, uint256 amountB) {
        address pair = CrossLibrary.pairFor(factory, tokenA, tokenB);
        
        (uint256 reserve0, uint256 reserve1, ) = ICrossPair(pair).getReserves();
        _initializeOSLiquidity(pair, reserve0, reserve1); // Liquidity control

        ICrossPair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (uint256 amount0, uint256 amount1) = ICrossPair(pair).burn(to);

        _ruleOutInvalidLiquidity(pair, reserve0, reserve1); // Liquidity control

        (address token0, ) = CrossLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);

        if (dsParams.isOriginAction) { // Transform must-arrive-at-pair amount to must-depart-from-user amount, then payFee.
            FeeRates memory rates = feeRatesArray[uint256(dsParams.sessionType)];
            if (tokenA == crssContract) {
                amountA -= _payFee(msg.sender, amountA, rates);
            } else if (tokenB == crssContract) {
                amountB -= _payFee(msg.sender, amountB, rates);
            }
        }
        require(amountA >= amountAMin, "CrossRouter: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "CrossRouter: INSUFFICIENT_B_AMOUNT");
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) session(SessionType.RemoveLiquidity) returns (uint256 amountA, uint256 amountB) {
        (amountA, amountB) = _removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to);
    }

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) session(SessionType.RemoveLiquidity) returns (uint256 amountToken, uint256 amountETH) {
        (amountToken, amountETH) = _removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this)
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint256 amountA, uint256 amountB) {
        address pair = CrossLibrary.pairFor(factory, tokenA, tokenB);
        uint256 value = approveMax ? type(uint256).max : liquidity;
        ICrossPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint256 amountToken, uint256 amountETH) {
        address pair = CrossLibrary.pairFor(factory, token, WETH);
        uint256 value = approveMax ? type(uint256).max : liquidity;
        ICrossPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquiditySupportingFeeOnTransferTokens(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) session(SessionType.RemoveLiquidity) returns (uint256 amountA, uint256 amountB) {
        address pair = CrossLibrary.pairFor(factory, tokenA, tokenB);

        //NOTE: The space amountA/B is stolen for reserve0/1, respectively, temporarilly, to avoid stack-too-deep error.
        (amountA, amountB, ) = ICrossPair(pair).getReserves();
        _initializeOSLiquidity(pair, amountA, amountB); // Liquidity control        

        address _tokenA = tokenA;
        address _tokenB = tokenB;
        ICrossPair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (uint256 amount0, uint256 amount1) = ICrossPair(pair).burn(to);
        (address token0, ) = CrossLibrary.sortTokens(_tokenA, _tokenB);

        _ruleOutInvalidLiquidity(pair, amountA, amountB); // Liquidity control

        (amountA, amountB) = _tokenA == token0 ? (amount0, amount1) : (amount1, amount0);

        if (dsParams.isOriginAction) { // Transform must-arrive-at-pair amount to must-depart-from-user amount, then payFee.
            FeeRates memory rates = feeRatesArray[uint256(dsParams.sessionType)];
            if (_tokenA == crssContract) {
                amountA -= _payFee(msg.sender, amountA, rates);
            } else if (_tokenB == crssContract) {
                amountB -= _payFee(msg.sender, amountB, rates);
            }
        }
        require(amountA >= amountAMin, "CrossRouter: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "CrossRouter: INSUFFICIENT_B_AMOUNT");
    }

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) session(SessionType.RemoveLiquidity) returns (uint256 amountETH) {
        (, amountETH) = _removeLiquidity(token, WETH, liquidity, amountTokenMin, amountETHMin, address(this));
        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint256 amountETH) {
        address pair = CrossLibrary.pairFor(factory, token, WETH);
        uint256 value = approveMax ? type(uint256).max : liquidity;
        ICrossPair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token,
            liquidity,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address _to
    ) internal virtual {

        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            ICrossPair pair = ICrossPair(CrossLibrary.pairFor(factory, input, output));
            (address token0, address token1) = CrossLibrary.sortTokens(input, output);

            bool isNichePair = chainlinkFeeds[token0].proxy == address(0) || chainlinkFeeds[token1].proxy == address(0);
            if (isNichePair)  _initializeOSNichePrice(address(pair), token0, token1); // Price control

            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));
            address to = i < path.length - 2 ? CrossLibrary.pairFor(factory, output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));

            _ruleOutInvalidPrice(isNichePair, address(pair), token0, token1); // Price control
        }
    }

    function _initializeOSNichePrice(address pair, address token0, address token1) internal virtual {
        if (initialPairPrices[pair].originSession != dsParams.originSession ) {
            initialPairPrices[pair].price = _getPrice1e23(pair, token0, token1); 
            initialPairPrices[pair].originSession = dsParams.originSession;
        }
    }

    function _ruleOutInvalidPrice(bool isNichePair, address pair, address token0, address token1) internal view virtual {
        int256 minPrice1e23; int256 maxPrice1e23;
        int256 newPrice1e23 = _getPrice1e23(pair, token0, token1);
        if ( isNichePair ) {
            (minPrice1e23, maxPrice1e23) = _getNichePairPrice1e23Range(initialPairPrices[pair].price);
        } else {
            (minPrice1e23, maxPrice1e23) = ChainLink.getChainLinkPrice1e23Range(chainlinkFeeds, token0, token1, zValuePerRuleOutPercent[5 - 1]); // 5: RuleOutPercent
        }
        require(minPrice1e23 <= newPrice1e23 && newPrice1e23 <= maxPrice1e23, "CrossRouter: Deviation from ChainLink price");
    }

    function _getPrice1e23(address pair, address token0, address token1) internal view virtual returns (int256 price1e23) {
        (uint256 reserve0, uint256 reserve1, ) = ICrossPair(pair).getReserves();
        uint8 decimal0 = IERC20Metadata(token0).decimals();
        uint8 decimal1 = IERC20Metadata(token1).decimals();
        price1e23 = int256( reserve0 * 10 ** (23 + decimal1 - decimal0) / reserve1 );
    }

    function _getNichePairPrice1e23Range(int256 priceOrg23) internal view virtual returns (int256 min1e1e23, int256 max1e23) {
        (min1e1e23, max1e23) = (priceOrg23 * int256(FeeMagnifier) / originSessionPriceChangeLimit, priceOrg23 * originSessionPriceChangeLimit / int256(FeeMagnifier) );
    }


    //int256 constant M4 = int256(10 ** (FeeMagnifierPower + 4));

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) session(SessionType.Swap) returns (uint256[] memory amounts) {

        FeeRates memory rates = feeRatesArray[uint256(dsParams.sessionType)];
        amountIn -= _payPossibleSellFee(path[0], msg.sender, amountIn, rates);

        amounts = CrossLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "CrossRouter: INSUFFICIENT_OUTPUT_AMOUNT");

        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender, 
            CrossLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );

        _swapWithPossibleBuyFee(amounts, path, rates, to);
    }

    function _payPossibleSellFee(address firstPath, address payer, uint256 principal, FeeRates memory rates)
    internal virtual returns (uint256 feesPaied) {
        if (dsParams.isOriginAction && firstPath == crssContract) {
            feesPaied = _payFee(payer, principal, rates);
        }
    }

    function _swapWithPossibleBuyFee(uint256[] memory amounts, address[] calldata path, FeeRates memory rates, address to)
    internal virtual returns (uint256 feesPaied) {
        if (dsParams.isOriginAction && path[path.length-1] == crssContract) {
            address detour = address(this);
            uint256 balance0 = ICrssToken(crssContract).balanceOf(detour);
            _swap(amounts, path, detour);
            uint256 amountOut = ICrssToken(crssContract).balanceOf(detour) - balance0;
            amountOut -= _payFee(detour, amountOut, rates);
            if( detour != to) TransferHelper.safeTransferFrom(crssContract, detour, to, amountOut);
        } else {
            _swap(amounts, path, to);
        }
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) session(SessionType.Swap) returns (uint256[] memory amounts) {

        amounts = CrossLibrary.getAmountsIn(factory, amountOut, path);

        FeeRates memory rates = feeRatesArray[uint256(dsParams.sessionType)];
        uint256 amountIn = _getOuterFeeAdded(amounts[0], rates);
        require(amountIn <= amountInMax, "CrossRouter: EXCESSIVE_INPUT_AMOUNT");
        _payPossibleSellFee(path[0], msg.sender, amountIn, rates);

        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            CrossLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );

        _swapWithPossibleBuyFee(amounts, path, rates, to);
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override ensure(deadline) session(SessionType.Swap) returns (uint256[] memory amounts) {
        require(path[0] == WETH, "CrossRouter: INVALID_PATH");       
        amounts = CrossLibrary.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "CrossRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(CrossLibrary.pairFor(factory, path[0], path[1]), amounts[0]));

        FeeRates memory rates = feeRatesArray[uint256(dsParams.sessionType)];
        _swapWithPossibleBuyFee(amounts, path, rates, to);
    }

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) session(SessionType.Swap) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "CrossRouter: INVALID_PATH");
        amounts = CrossLibrary.getAmountsIn(factory, amountOut, path);

        FeeRates memory rates = feeRatesArray[uint256(dsParams.sessionType)];
        uint256 amountIn = _getOuterFeeAdded(amounts[0], rates);
        require(amountIn <= amountInMax, "CrossRouter: EXCESSIVE_INPUT_AMOUNT");
        _payPossibleSellFee(path[0], msg.sender, amountIn, rates);

        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            CrossLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) session(SessionType.Swap) returns (uint256[] memory amounts) {

        FeeRates memory rates = feeRatesArray[uint256(dsParams.sessionType)];
        amountIn -= _payPossibleSellFee(path[0], msg.sender, amountIn, rates);

        require(path[path.length - 1] == WETH, "CrossRouter: INVALID_PATH");
        amounts = CrossLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "CrossRouter: INSUFFICIENT_OUTPUT_AMOUNT");

        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            CrossLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override ensure(deadline) session(SessionType.Swap) returns (uint256[] memory amounts) {
        require(path[0] == WETH, "CrossRouter: INVALID_PATH");
        amounts = CrossLibrary.getAmountsIn(factory, amountOut, path);

        require(amounts[0] <= msg.value, "CrossRouter: EXCESSIVE_INPUT_AMOUNT");
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(CrossLibrary.pairFor(factory, path[0], path[1]), amounts[0]));

        FeeRates memory rates = feeRatesArray[uint256(dsParams.sessionType)];
        _swapWithPossibleBuyFee(amounts, path, rates, to);

        // refund dust eth, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {

        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, address token1 ) = CrossLibrary.sortTokens(input, output);
            ICrossPair pair = ICrossPair(CrossLibrary.pairFor(factory, input, output));

            bool isNichePair = chainlinkFeeds[token0].proxy == address(0) || chainlinkFeeds[token1].proxy == address(0);
            if (isNichePair)  _initializeOSNichePrice(address(pair), token0, token1); // Price control

            uint256 amountOutput;
            {
                uint256 amountInput;
                // scope to avoid stack too deep errors
                (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
                (uint256 reserveInput, uint256 reserveOutput) = input == token0
                    ? (reserve0, reserve1) : (reserve1, reserve0);
                amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
                amountOutput = CrossLibrary.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOutput) : (amountOutput, uint256(0));
            address to = i < path.length - 2 ? CrossLibrary.pairFor(factory, output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));

            _ruleOutInvalidPrice(isNichePair, address(pair), token0, token1); // Price control
        }
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) session(SessionType.Swap) {

        FeeRates memory rates = feeRatesArray[uint256(dsParams.sessionType)];
        amountIn -= _payPossibleSellFee(path[0], msg.sender, amountIn, rates);

        TransferHelper.safeTransferFrom(path[0], msg.sender, CrossLibrary.pairFor(factory, path[0], path[1]), amountIn);
        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        
        _swapSupportingFeeOnTransferTokensWithPossibleBuyFee(path, rates, to);

        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            "CrossRouter: INSUFFICIENT_OUTPUT_AMOUNT"
        );


    }


    function _swapSupportingFeeOnTransferTokensWithPossibleBuyFee(address[] calldata path, FeeRates memory rates, address to)
    internal virtual returns (uint256 feesPaied) {
        if (dsParams.isOriginAction && path[path.length-1] == crssContract) {
            address detour = address(this);
            uint256 balance0 = ICrssToken(crssContract).balanceOf(detour);
            _swapSupportingFeeOnTransferTokens(path, detour);
            uint256 amountOut = ICrssToken(crssContract).balanceOf(detour) - balance0;
            amountOut -= _payFee(detour, amountOut, rates);
            if( detour != to) TransferHelper.safeTransferFrom(crssContract, detour, to, amountOut);
        } else {
            _swapSupportingFeeOnTransferTokens(path, to);
        }

    }


    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override ensure(deadline) session(SessionType.Swap) {
        require(path[0] == WETH, "CrossRouter: INVALID_PATH");
        uint256 amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        assert(IWETH(WETH).transfer(CrossLibrary.pairFor(factory, path[0], path[1]), amountIn));
        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);

        FeeRates memory rates = feeRatesArray[uint256(dsParams.sessionType)];
        _swapSupportingFeeOnTransferTokensWithPossibleBuyFee(path, rates, to);

        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            "CrossRouter: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) session(SessionType.Swap) {
        require(path[path.length - 1] == WETH, "CrossRouter: INVALID_PATH");

        FeeRates memory rates = feeRatesArray[uint256(dsParams.sessionType)];
        amountIn -= _payPossibleSellFee(path[0], msg.sender, amountIn, rates);

        TransferHelper.safeTransferFrom(path[0], msg.sender, CrossLibrary.pairFor(factory, path[0], path[1]), amountIn);
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint256 amountOut = IERC20(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, "CrossRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IWETH(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) public pure virtual override returns (uint256 amountB) {
        return CrossLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure virtual override returns (uint256 amountOut) {
        return CrossLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure virtual override returns (uint256 amountIn) {
        return CrossLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint256 amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (uint256[] memory amounts)
    {
        return CrossLibrary.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (uint256[] memory amounts)
    {
        return CrossLibrary.getAmountsIn(factory, amountOut, path);
    }
}

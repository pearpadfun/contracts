// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

//                             ▄████
//                            ▄████
//                            ███▀
//                            ██
//                 ▄█████████▄
//               ▄█████████████▄
//               ███████████████
//               ███████████████
//              ▄██████████████▀
//             ▄██████████████
//           ▄████████████████
//          ▄█████████████████
//         ▄██████████████████▄
//         █████████████████████▄▄
//         ████████████████████████▄▄
//         ███████████████████████████
//         ███████████████████████████
//          █████████████████████████
//           ▀█████████████████████▀
//             ▀▀████████████████▀
//                 ▀▀▀▀▀▀▀▀▀▀▀▀
//
//  ██████╗ ███████╗ █████╗ ██████╗ ██████╗  █████╗ ██████╗
//  ██╔══██╗██╔════╝██╔══██╗██╔══██╗██╔══██╗██╔══██╗██╔══██╗
//  ██████╔╝█████╗  ███████║██████╔╝██████╔╝███████║██║  ██║
//  ██╔═══╝ ██╔══╝  ██╔══██║██╔══██╗██╔═══╝ ██╔══██║██║  ██║
//  ██║     ███████╗██║  ██║██║  ██║██║     ██║  ██║██████╔╝
//  ╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝  ╚═╝╚═════╝
//
//  pear-v3.0.0 · Stable chain (id 988) · https://pearpad.fun · © 2026 PEARPAD

import {PearpadToken} from "./PearpadToken.sol";
import {PearpadLocker, IPositionManagerCollect} from "./PearpadLocker.sol";
import {ISwapRouter} from "./PearpadLocker.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IUniswapV3Pool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

contract PearpadFactory {
    using SafeERC20 for IERC20;

    uint24 public constant POOL_FEE = 10_000;
    uint256 public constant TUNING_TOLERANCE_BPS = 10;
    int24 internal constant MIN_TICK = -887200;
    int24 internal constant MAX_TICK = 887200;

    struct Config {
        uint128 virtualUsdt;
        uint128 targetUsdt;
        uint128 totalSupply;
        uint128 virtualTokens;
        uint16 creatorBps;
        uint16 treasuryBps;
        uint16 lpCreatorBps;
    }

    struct Curve {
        uint256 ethReserve;
        uint256 tokenReserve;
        address creator;
        bool migrated;
        Config cfg;
    }

    IERC20 public immutable usdt0;

    INonfungiblePositionManager public positionManager;
    address public swapRouter;
    PearpadLocker public lpLocker;

    address public treasury;

    Config public defaultConfig;

    mapping(address => Curve) public curves;
    mapping(address => uint256) public feesOwed;
    uint256 public launchFee;
    bool public paused;

    address private expectedPool;

    event Launched(address indexed token, address indexed creator, string metadata, Config cfg);
    event Bought(
        address indexed token,
        address indexed buyer,
        uint256 ethIn,
        uint256 tokensOut,
        uint256 ethReserve,
        uint256 tokenReserve
    );
    event Sold(
        address indexed token,
        address indexed seller,
        uint256 tokensIn,
        uint256 ethOut,
        uint256 ethReserve,
        uint256 tokenReserve
    );
    event LaunchFeeChanged(uint256 newFee);
    event TreasuryChanged(address indexed newTreasury);
    event PausedSet(bool paused);
    event Migrated(address indexed token, address pool, uint256 tokenId);
    event CreatorChanged(address indexed token, address indexed newCreator);
    event DefaultConfigChanged(Config cfg);
    event AddressSet(bytes32 indexed key, address value);

    modifier onlyTreasury() {
        require(msg.sender == treasury, "not treasury");
        _;
    }

    constructor(
        IERC20 usdt0_,
        INonfungiblePositionManager positionManager_,
        ISwapRouter swapRouter_,
        address treasury_,
        Config memory cfg
    ) {
        require(treasury_ != address(0), "zero treasury");
        usdt0 = usdt0_;
        positionManager = positionManager_;
        swapRouter = address(swapRouter_);
        treasury = treasury_;
        _setDefaultConfig(cfg);
        lpLocker = new PearpadLocker(
            IPositionManagerCollect(address(positionManager_)), swapRouter_, address(usdt0_), treasury_
        );
    }

    function _setDefaultConfig(Config memory cfg) internal {
        require(cfg.virtualUsdt > 0 && cfg.targetUsdt > 0, "zero curve");
        require(cfg.virtualTokens > 0 && cfg.totalSupply > 0, "bad supply");
        uint256 left = uint256(cfg.virtualTokens) * cfg.virtualUsdt / (uint256(cfg.virtualUsdt) + cfg.targetUsdt);
        require(uint256(cfg.virtualTokens) - left <= cfg.totalSupply, "supply too low");

        require(_isTuned(cfg), "virtualTokens untuned");
        require(cfg.lpCreatorBps <= 10_000, "bad share");
        require(uint256(cfg.targetUsdt) % 1e12 == 0, "target not 1e12-divisible");
        defaultConfig = cfg;
        emit DefaultConfigChanged(cfg);
    }

    function setDefaultConfig(Config calldata cfg) external onlyTreasury {
        _setDefaultConfig(cfg);
    }

    function tunedVirtualTokens(uint256 virtualUsdt_, uint256 targetUsdt_, uint256 totalSupply_)
        public
        pure
        returns (uint256)
    {
        uint256 sum = virtualUsdt_ + targetUsdt_;
        return Math.mulDiv(Math.mulDiv(totalSupply_, sum, targetUsdt_), sum, targetUsdt_ + 2 * virtualUsdt_);
    }

    function _isTuned(Config memory cfg) internal pure returns (bool) {
        uint256 tuned = tunedVirtualTokens(cfg.virtualUsdt, cfg.targetUsdt, cfg.totalSupply);
        uint256 drift = cfg.virtualTokens > tuned ? cfg.virtualTokens - tuned : tuned - cfg.virtualTokens;
        return drift <= Math.mulDiv(tuned, TUNING_TOLERANCE_BPS, 10_000);
    }

    function configOf(address token) external view returns (Config memory) {
        return curves[token].cfg;
    }

    function creatorShareOf(address token) external view returns (uint16) {
        return curves[token].cfg.lpCreatorBps;
    }

    function creatorOf(address token) external view returns (address) {
        return curves[token].creator;
    }

    function setCreator(address token, address newCreator) external {
        Curve storage c = curves[token];
        require(c.creator != address(0), "unknown token");
        require(msg.sender == c.creator || msg.sender == treasury, "not authorized");
        require(newCreator != address(0), "zero creator");
        c.creator = newCreator;
        emit CreatorChanged(token, newCreator);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        require(newTreasury != address(0), "zero treasury");
        // the locker keeps its own treasury; rotate it separately or LP fees
        // keep paying the old address
        uint256 owed = feesOwed[treasury];
        if (owed > 0) {
            feesOwed[treasury] = 0;
            feesOwed[newTreasury] += owed;
        }
        treasury = newTreasury;
        emit TreasuryChanged(newTreasury);
    }

    function setPaused(bool paused_) external onlyTreasury {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setLaunchFee(uint256 newFee) external onlyTreasury {
        launchFee = newFee;
        emit LaunchFeeChanged(newFee);
    }

    function setAddress(bytes32 key, address value) external onlyTreasury {
        require(value != address(0), "zero address");
        if (key == "positionManager") positionManager = INonfungiblePositionManager(value);
        else if (key == "swapRouter") swapRouter = value;
        else if (key == "lpLocker") lpLocker = PearpadLocker(value);
        else revert("bad key");
        emit AddressSet(key, value);
    }

    function launch(string calldata name, string calldata symbol, string calldata metadata, uint256 maxFee)
        external
        payable
        returns (address token)
    {
        require(!paused, "paused");
        require(launchFee <= maxFee, "fee raised");
        require(msg.value >= launchFee, "insufficient fee");
        feesOwed[treasury] += launchFee;

        Config memory cfg = defaultConfig;
        token = address(new PearpadToken(name, symbol, metadata, msg.sender, cfg.totalSupply));
        Curve storage c = curves[token];
        c.tokenReserve = cfg.virtualTokens;
        c.creator = msg.sender;
        c.cfg = cfg;
        emit Launched(token, msg.sender, metadata, cfg);

        uint256 devBuy = msg.value - launchFee;
        if (devBuy > 0) _buy(token, c, devBuy, 0);
    }

    function _takeFee(Curve storage c, uint256 grossEth) internal returns (uint256 fee) {
        Config storage cfg = c.cfg;
        uint256 creatorCut = grossEth * cfg.creatorBps / 10_000;
        uint256 treasuryCut = grossEth * cfg.treasuryBps / 10_000;
        feesOwed[c.creator] += creatorCut;
        feesOwed[treasury] += treasuryCut;
        fee = creatorCut + treasuryCut;
    }

    function claimFees() external {
        uint256 amount = feesOwed[msg.sender];
        feesOwed[msg.sender] = 0;
        _sendFees(msg.sender, amount);
    }

    function collectFees(address token) external {
        Curve storage c = curves[token];
        address creator = c.creator;
        require(creator != address(0), "unknown token");
        // zero both balances before any external call; sequential so
        // creator == treasury cannot read the same balance twice
        uint256 creatorOwed = feesOwed[creator];
        feesOwed[creator] = 0;
        address treasury_ = treasury;
        uint256 treasuryOwed = feesOwed[treasury_];
        feesOwed[treasury_] = 0;
        if (c.migrated) lpLocker.collect(lpLocker.positionOf(token));
        _sendFees(creator, creatorOwed);
        _sendFees(treasury_, treasuryOwed);
    }

    function _sendFees(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "claim failed");
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    function getTokensOut(address token, uint256 ethIn) public view returns (uint256) {
        Curve storage c = curves[token];
        uint256 e = c.cfg.virtualUsdt + c.ethReserve;
        return c.tokenReserve - _divUp(e * c.tokenReserve, e + ethIn);
    }

    function getEthOut(address token, uint256 tokensIn) public view returns (uint256) {
        Curve storage c = curves[token];
        uint256 e = c.cfg.virtualUsdt + c.ethReserve;
        return e - _divUp(e * c.tokenReserve, c.tokenReserve + tokensIn);
    }

    function buy(address token, uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        return _buy(token, curves[token], msg.value, minTokensOut);
    }

    function _buy(address token, Curve storage c, uint256 value, uint256 minTokensOut)
        internal
        returns (uint256 tokensOut)
    {
        require(c.tokenReserve > 0 && !c.migrated, "not tradeable");
        require(value > 0, "zero eth");
        Config storage cfg = c.cfg;
        uint256 target = cfg.targetUsdt;

        uint256 ethIn = value * 10_000 / (10_000 + uint256(cfg.creatorBps) + cfg.treasuryBps);
        if (c.ethReserve + ethIn > target) {
            ethIn = target - c.ethReserve;
        }
        uint256 fee = _takeFee(c, ethIn);
        uint256 refund = value - ethIn - fee;

        tokensOut = getTokensOut(token, ethIn);
        require(tokensOut >= minTokensOut, "slippage");

        c.ethReserve += ethIn;
        c.tokenReserve -= tokensOut;
        IERC20(token).safeTransfer(msg.sender, tokensOut);
        emit Bought(token, msg.sender, ethIn, tokensOut, c.ethReserve, c.tokenReserve);

        if (c.ethReserve == target) _migrate(token, c);
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "refund failed");
        }
    }

    function sell(address token, uint256 tokensIn, uint256 minEthOut) external returns (uint256 ethOut) {
        Curve storage c = curves[token];
        require(c.creator != address(0), "unknown token");
        require(!c.migrated, "migrated");
        uint256 grossOut = getEthOut(token, tokensIn);
        c.ethReserve -= grossOut;
        c.tokenReserve += tokensIn;
        ethOut = grossOut - _takeFee(c, grossOut);
        require(ethOut >= minEthOut, "slippage");
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "eth send failed");
        emit Sold(token, msg.sender, tokensIn, ethOut, c.ethReserve, c.tokenReserve);
    }

    function _migrate(address token, Curve storage c) internal {
        c.migrated = true;

        uint256 usdtAmount = c.ethReserve / 1e12;
        uint256 tokenAmount = IERC20(token).balanceOf(address(this));

        (address token0, address token1) = token < address(usdt0) ? (token, address(usdt0)) : (address(usdt0), token);
        (uint256 amount0, uint256 amount1) = token0 == token ? (tokenAmount, usdtAmount) : (usdtAmount, tokenAmount);

        uint160 sqrtPriceX96 = uint160((_sqrt(amount1 * 1e36 / amount0) * (2 ** 96)) / 1e18);

        address pool = positionManager.createAndInitializePoolIfNecessary(token0, token1, POOL_FEE, sqrtPriceX96);

        (amount0, amount1) = _correctPool(pool, sqrtPriceX96, amount0, amount1, abi.encode(token0, token1));

        uint256 tokenId = _mintLocked(token, token0, token1, amount0, amount1);
        emit Migrated(token, pool, tokenId);
    }

    function _mintLocked(address token, address token0, address token1, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId)
    {
        IERC20(token).forceApprove(address(positionManager), token0 == token ? amount0 : amount1);
        usdt0.forceApprove(address(positionManager), token0 == token ? amount1 : amount0);

        (tokenId,,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: POOL_FEE,
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(lpLocker),
                deadline: block.timestamp
            })
        );

        IERC20(token).forceApprove(address(positionManager), 0);
        usdt0.forceApprove(address(positionManager), 0);
        lpLocker.register(tokenId, token);
    }

    function _correctPool(address pool, uint160 target, uint256 amount0, uint256 amount1, bytes memory data)
        internal
        returns (uint256, uint256)
    {
        (uint160 current,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (current == target) return (amount0, amount1);
        bool zeroForOne = current > target;
        expectedPool = pool;
        (int256 delta0, int256 delta1) =
            IUniswapV3Pool(pool).swap(address(this), zeroForOne, int256(zeroForOne ? amount0 : amount1), target, data);
        expectedPool = address(0);
        return (uint256(int256(amount0) - delta0), uint256(int256(amount1) - delta1));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == expectedPool && msg.sender != address(0), "bad callback");
        (address token0, address token1) = abi.decode(data, (address, address));
        if (amount0Delta > 0) IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

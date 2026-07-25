// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

//                       ▄▄
//                      ▐██▌
//                  ▄████████▄
//                ▄███▀    ▀███▄
//               ▐███      ███▌
//               ▐███▄    ▄███▌
//                ▀████▄▄▄▄████▀
//                  ▀▀██████▀▀
//
//  ██████╗ ███████╗ █████╗ ██████╗ ██████╗  █████╗ ██████╗
//  ██╔══██╗██╔════╝██╔══██╗██╔══██╗██╔══██╗██╔══██╗██╔══██╗
//  ██████╔╝█████╗  ███████║██████╔╝██████╔╝███████║██║  ██║
//  ██╔═══╝ ██╔══╝  ██╔══██║██╔══██╗██╔═══╝ ██╔══██║██║  ██║
//  ██║     ███████╗██║  ██║██║  ██║██║     ██║  ██║██████╔╝
//  ╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝  ╚═╝╚═════╝
//
//  pear-v1.0.0 · Stable chain (id 988) · https://pearpad.fun · © 2026 PEARPAD

import {PearpadToken} from "./PearpadToken.sol";
import {PearpadLocker, IPositionManagerCollect} from "./PearpadLocker.sol";
import {ISwapRouter} from "./PearpadLocker.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// @notice Bonding-curve token factory; at TARGET_USDT the curve migrates to Uniswap V3.
contract PearpadFactory {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether; // rest seeds the LP
    uint256 public constant VIRTUAL_USDT = 2500 ether; // native USDT0, 18 decimals
    uint256 public constant TARGET_USDT = 10_000 ether; // 1:4 ratio vs virtual reserve

    uint256 public constant FEE_BPS = 100; // split 60/40 creator/treasury
    uint256 public constant PROTOCOL_FEE_BPS = 30; // treasury only; total curve fee = 1.3%
    uint256 public constant CREATOR_SHARE_BPS = 6000;

    uint24 public constant POOL_FEE = 10_000; // 1% tier — every pool swap pays the locked LP
    int24 internal constant MIN_TICK = -887200; // full range at tick spacing 200
    int24 internal constant MAX_TICK = 887200;

    IERC20 public immutable usdt0; // dual-role: this contract's native balance IS its USDT0 ERC-20 balance (6 dec)
    INonfungiblePositionManager public immutable positionManager;
    PearpadLocker public immutable lpLocker;

    address public treasury;

    struct Curve {
        uint256 ethReserve; // real native USDT0 (18 dec) only, virtual excluded
        uint256 tokenReserve;
        address creator;
        bool migrated;
    }

    mapping(address => Curve) public curves;
    mapping(address => uint256) public feesOwed; // claimable native USDT0
    uint256 public launchFee;
    bool public paused; // blocks new launches only; trading is never paused
    address private expectedPool; // nonzero only during the migration correction swap

    event Launched(address indexed token, address indexed creator, string metadata);
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

    constructor(IERC20 usdt0_, INonfungiblePositionManager positionManager_, ISwapRouter swapRouter_, address treasury_)
    {
        usdt0 = usdt0_;
        positionManager = positionManager_;
        treasury = treasury_;
        lpLocker =
            new PearpadLocker(IPositionManagerCollect(address(positionManager_)), swapRouter_, address(usdt0_), treasury_);
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

    // value beyond launchFee executes the creator's first buy atomically
    function launch(string calldata name, string calldata symbol, string calldata metadata, uint256 maxFee)
        external
        payable
        returns (address token)
    {
        require(!paused, "paused");
        require(launchFee <= maxFee, "fee raised");
        require(msg.value >= launchFee, "insufficient fee");
        feesOwed[treasury] += launchFee;

        token = address(new PearpadToken(name, symbol, metadata, msg.sender, TOTAL_SUPPLY));
        curves[token] = Curve({ethReserve: 0, tokenReserve: CURVE_SUPPLY, creator: msg.sender, migrated: false});
        emit Launched(token, msg.sender, metadata);

        uint256 devBuy = msg.value - launchFee;
        if (devBuy > 0) _buy(token, curves[token], devBuy, 0);
    }

    function setTreasury(address newTreasury) external {
        require(msg.sender == treasury, "not treasury");
        require(newTreasury != address(0), "zero treasury");
        treasury = newTreasury;
        emit TreasuryChanged(newTreasury);
    }

    // blocks new launches only; trading is never paused
    function setPaused(bool paused_) external {
        require(msg.sender == treasury, "not treasury");
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setLaunchFee(uint256 newFee) external {
        require(msg.sender == treasury, "not treasury");
        launchFee = newFee;
        emit LaunchFeeChanged(newFee);
    }

    function _takeFee(Curve storage c, uint256 grossEth) internal returns (uint256 fee) {
        fee = grossEth * (FEE_BPS + PROTOCOL_FEE_BPS) / 10_000;
        uint256 creatorCut = grossEth * FEE_BPS * CREATOR_SHARE_BPS / 100_000_000;
        feesOwed[c.creator] += creatorCut;
        feesOwed[treasury] += fee - creatorCut;
    }

    function claimFees() external {
        uint256 amount = feesOwed[msg.sender];
        feesOwed[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "claim failed");
    }

    // Pricing: constant product over (VIRTUAL_USDT + ethReserve, tokenReserve).

    // Rounds up: both quotes subtract this from a reserve, so flooring would round the payout up
    // and a full exit could quote 1 wei more than the reserve holds.
    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    function getTokensOut(address token, uint256 ethIn) public view returns (uint256) {
        Curve storage c = curves[token];
        uint256 e = VIRTUAL_USDT + c.ethReserve;
        return c.tokenReserve - _divUp(e * c.tokenReserve, e + ethIn);
    }

    function getEthOut(address token, uint256 tokensIn) public view returns (uint256) {
        Curve storage c = curves[token];
        uint256 e = VIRTUAL_USDT + c.ethReserve;
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

        uint256 ethIn = value * 10_000 / (10_000 + FEE_BPS + PROTOCOL_FEE_BPS);
        // cap at the migration target, refund the rest
        if (c.ethReserve + ethIn > TARGET_USDT) {
            ethIn = TARGET_USDT - c.ethReserve;
        }
        uint256 fee = _takeFee(c, ethIn);
        uint256 refund = value - ethIn - fee;

        tokensOut = getTokensOut(token, ethIn);
        require(tokensOut >= minTokensOut, "slippage");

        c.ethReserve += ethIn;
        c.tokenReserve -= tokensOut;
        IERC20(token).transfer(msg.sender, tokensOut);
        emit Bought(token, msg.sender, ethIn, tokensOut, c.ethReserve, c.tokenReserve);

        if (c.ethReserve == TARGET_USDT) _migrate(token, c);
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
        IERC20(token).transferFrom(msg.sender, address(this), tokensIn);
        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "eth send failed");
        emit Sold(token, msg.sender, tokensIn, ethOut, c.ethReserve, c.tokenReserve);
    }

    function _migrate(address token, Curve storage c) internal {
        c.migrated = true;

        // no wrapping on Stable: the native reserve is already spendable as USDT0 ERC-20, 6 decimals
        uint256 usdtAmount = c.ethReserve / 1e12;
        // unsold curve remainder plus the LP reserve all goes to the pool
        uint256 tokenAmount = IERC20(token).balanceOf(address(this));

        (address token0, address token1) = token < address(usdt0) ? (token, address(usdt0)) : (address(usdt0), token);
        (uint256 amount0, uint256 amount1) =
            token0 == token ? (tokenAmount, usdtAmount) : (usdtAmount, tokenAmount);

        // sqrtPriceX96 = sqrt(amount1/amount0) * 2^96; 1e36 scale keeps precision across the 6/18-dec gap
        uint160 sqrtPriceX96 = uint160((_sqrt(amount1 * 1e36 / amount0) * (2 ** 96)) / 1e18);

        address pool = positionManager.createAndInitializePoolIfNecessary(token0, token1, POOL_FEE, sqrtPriceX96);

        // corrects a pre-initialized pool back to the curve price before minting
        (amount0, amount1) = _correctPool(pool, sqrtPriceX96, amount0, amount1, abi.encode(token0, token1));
        (tokenAmount, usdtAmount) = token0 == token ? (amount0, amount1) : (amount1, amount0);

        IERC20(token).approve(address(positionManager), tokenAmount);
        usdt0.approve(address(positionManager), usdtAmount);

        (uint256 tokenId,,,) = positionManager.mint(
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

        usdt0.approve(address(positionManager), 0); // never leave a live USDT0 allowance
        lpLocker.register(tokenId, token);
        emit Migrated(token, pool, tokenId);
    }

    // Swaps a pre-initialized pool to our price, then reports what we still hold. Uses the swap's
    // own deltas, not balanceOf: this contract's USDT0 balance is shared across every migration.
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
        if (amount0Delta > 0) IERC20(token0).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(token1).transfer(msg.sender, uint256(amount1Delta));
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

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
//  pear-launch-hype-v1.2.0 · HyperEVM (id 999) · https://pearpad.fun · © 2026 PEARPAD

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {PearpadLaunchToken} from "./PearpadLaunchToken.sol";
import {PearpadLocker} from "./PearpadLocker.sol";

interface IUniswapV3PoolState {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function tickSpacing() external view returns (int24);

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWHYPE {
    function deposit() external payable;
}

interface INonfungiblePositionManager {
    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool);

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

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
}

contract PearpadLauncher is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum StartMcap {
        MCAP_50,
        MCAP_100,
        MCAP_250,
        MCAP_500
    }

    struct SeedBuy {
        address recipient;
        uint256 amountIn;
        uint256 minOut;
    }

    struct LaunchParams {
        string name;
        string symbol;
        string metadata;
        StartMcap startMcap;
        bytes32 salt;
        uint256 venueId;
    }

    struct Venue {
        address positionManager;
        address swapRouter;
        bool enabled;
    }

    struct Position {
        address token;
        address pool;
        address creator;
        bool tokenIsToken0;
        address positionManager;
        address swapRouter;
        uint256 nftId;
    }

    uint256 public constant LAUNCH_FEE = 0.069e18;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint24 public constant POOL_FEE = 10_000;

    int24 internal constant MAX_TICK = 887_272;
    uint256 public constant CREATOR_SHARE_BPS = 6_000;
    uint256 internal constant BPS = 10_000;

    uint256 public constant CORRECTION_MAX_SUPPLY_BPS = 1_000;

    uint160 internal constant SQRT_MCAP_50_T0 = 17715955711429571029610171;
    uint160 internal constant SQRT_MCAP_50_T1 = 354319114228591420592203432321452;
    uint160 internal constant SQRT_MCAP_100_T0 = 25054144837504793118641380;
    uint160 internal constant SQRT_MCAP_100_T1 = 250541448375047931186413801569606;
    uint160 internal constant SQRT_MCAP_250_T0 = 39614081257132168796771975;
    uint160 internal constant SQRT_MCAP_250_T1 = 158456325028528675187087900672000;
    uint160 internal constant SQRT_MCAP_500_T0 = 56022770974786139918731938;
    uint160 internal constant SQRT_MCAP_500_T1 = 112045541949572279837463876454916;

    IERC20 public immutable whype;
    PearpadLocker public immutable locker;

    address public treasury;

    address internal expectedPool;

    Venue[] public venues;

    mapping(uint256 => Position) public launches;
    mapping(address => uint256) public launchIdOf;
    uint256 public launchCount;

    error PoolPriceMismatch(uint160 expected, uint160 actual);
    error BadCallback();
    error FeeNotPaid(uint256 sent, uint256 required);
    error BadSeedBuy();
    error QuoteMissing(uint256 have, uint256 need);
    error FeeTransferFailed();
    error RefundFailed();
    error NotTreasury();
    error NoSuchVenue(uint256 venueId);
    error VenueDisabled(uint256 venueId);
    error NoBlockEntropy();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    event Launched(
        address indexed token,
        address indexed pool,
        address indexed creator,
        uint256 launchId,
        uint256 venueId,
        uint256 nftId,
        StartMcap startMcap,
        bool tokenIsToken0,
        int24 tickLower,
        int24 tickUpper
    );

    event VenueAdded(uint256 indexed venueId, address positionManager, address swapRouter);
    event VenueEnabledSet(uint256 indexed venueId, bool enabled);
    event TreasuryChanged(address indexed newTreasury);

    event SeedBuyFilled(address indexed token, address indexed recipient, uint256 amountIn, uint256 amountOut);

    event LaunchFeePaid(address indexed payer, address indexed recipient, uint256 amount);

    event PoolCorrected(
        address indexed token,
        address indexed pool,
        uint160 foundAt,
        uint160 target,
        uint160 reached,
        uint256 supplySold,
        uint256 quoteReceived
    );

    constructor(
        IERC20 whype_,
        address positionManager0_,
        address swapRouter0_,
        address positionManager1_,
        address swapRouter1_,
        address treasury_
    ) {
        require(address(whype_) != address(0) && treasury_ != address(0), "zero address");
        whype = whype_;
        locker = new PearpadLocker(whype_);
        treasury = treasury_;
        _addVenue(positionManager0_, swapRouter0_);
        _addVenue(positionManager1_, swapRouter1_);
    }

    function addVenue(address positionManager_, address swapRouter_)
        external
        onlyTreasury
        returns (uint256 venueId)
    {
        return _addVenue(positionManager_, swapRouter_);
    }

    function setVenueEnabled(uint256 venueId, bool enabled) external onlyTreasury {
        if (venueId >= venues.length) revert NoSuchVenue(venueId);
        venues[venueId].enabled = enabled;
        emit VenueEnabledSet(venueId, enabled);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        require(newTreasury != address(0), "zero treasury");
        treasury = newTreasury;
        emit TreasuryChanged(newTreasury);
    }

    function venueCount() external view returns (uint256) {
        return venues.length;
    }

    function _addVenue(address positionManager_, address swapRouter_) internal returns (uint256 venueId) {
        require(positionManager_ != address(0) && swapRouter_ != address(0), "zero venue");
        venueId = venues.length;
        venues.push(Venue({positionManager: positionManager_, swapRouter: swapRouter_, enabled: true}));
        emit VenueAdded(venueId, positionManager_, swapRouter_);
        emit VenueEnabledSet(venueId, true);
    }

    function launch(LaunchParams calldata p, SeedBuy[] calldata seedBuys)
        external
        payable
        nonReentrant
        returns (address token, address pool, uint256 launchId)
    {
        uint256 seedTotal = _sumSeedBuys(seedBuys);
        uint256 required = LAUNCH_FEE + seedTotal;
        if (msg.value < required) revert FeeNotPaid(msg.value, required);

        bytes32 entropy = blockhash(block.number - 1);
        if (entropy == bytes32(0)) revert NoBlockEntropy();

        token = address(
            new PearpadLaunchToken{salt: keccak256(abi.encode(msg.sender, p.salt, entropy))}(
                p.name, p.symbol, p.metadata, msg.sender
            )
        );

        (pool, launchId) = _openPoolAndMint(token, p.startMcap, p.venueId);

        if (seedTotal > 0) _runSeedBuys(token, seedBuys, seedTotal, launches[launchId].swapRouter);

        _settle(token, required);
    }

    function _sumSeedBuys(SeedBuy[] calldata seedBuys) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < seedBuys.length; i++) {
            if (seedBuys[i].recipient == address(0) || seedBuys[i].amountIn == 0) revert BadSeedBuy();
            total += seedBuys[i].amountIn;
        }
    }

    function _settle(address token, uint256 required) internal {
        uint256 leftover = IERC20(token).balanceOf(address(this));
        if (leftover > 0) IERC20(token).safeTransfer(msg.sender, leftover);

        uint256 quoteLeft = whype.balanceOf(address(this));
        if (quoteLeft > 0) whype.safeTransfer(treasury, quoteLeft);

        (bool feeOk,) = treasury.call{value: LAUNCH_FEE}("");
        if (!feeOk) revert FeeTransferFailed();
        emit LaunchFeePaid(msg.sender, treasury, LAUNCH_FEE);

        uint256 refund = msg.value - required;
        if (refund > 0) {
            (bool refundOk,) = msg.sender.call{value: refund}("");
            if (!refundOk) revert RefundFailed();
        }
    }

    function _openPoolAndMint(address token, StartMcap startMcap, uint256 venueId)
        internal
        returns (address pool, uint256 launchId)
    {
        if (venueId >= venues.length) revert NoSuchVenue(venueId);
        Venue memory v = venues[venueId];
        if (!v.enabled) revert VenueDisabled(venueId);

        bool tokenIsToken0 = token < address(whype);
        int24 tickLower;
        int24 tickUpper;

        {
            uint160 sqrtPriceX96 = _startSqrtPriceX96(startMcap, tokenIsToken0);
            pool = INonfungiblePositionManager(v.positionManager).createAndInitializePoolIfNecessary(
                tokenIsToken0 ? token : address(whype), tokenIsToken0 ? address(whype) : token, POOL_FEE, sqrtPriceX96
            );

            (uint160 poolSqrt,,,,,,) = IUniswapV3PoolState(pool).slot0();
            if (poolSqrt != sqrtPriceX96) _correctPool(pool, sqrtPriceX96, tokenIsToken0, token);

            int24 curTick;
            (poolSqrt, curTick,,,,,) = IUniswapV3PoolState(pool).slot0();
            if (poolSqrt != sqrtPriceX96) revert PoolPriceMismatch(sqrtPriceX96, poolSqrt);

            int24 spacing = IUniswapV3PoolState(pool).tickSpacing();
            int24 maxUsable = (MAX_TICK / spacing) * spacing;

            if (tokenIsToken0) {
                tickLower = _ceilSpacing(curTick + 1, spacing);
                tickUpper = maxUsable;
            } else {
                tickLower = -maxUsable;
                tickUpper = _floorSpacing(curTick, spacing);
            }
        }

        uint256 nftId = _mintFullSupply(v.positionManager, token, tokenIsToken0, tickLower, tickUpper);

        IERC20(token).forceApprove(v.positionManager, 0);

        launchId = ++launchCount;
        locker.register(launchId, nftId, token, msg.sender, v.positionManager, v.swapRouter);
        launches[launchId] = Position({
            token: token,
            pool: pool,
            creator: msg.sender,
            tokenIsToken0: tokenIsToken0,
            positionManager: v.positionManager,
            swapRouter: v.swapRouter,
            nftId: nftId
        });
        launchIdOf[token] = launchId;

        emit Launched(
            token, pool, msg.sender, launchId, venueId, nftId, startMcap, tokenIsToken0, tickLower, tickUpper
        );
    }

    function _mintFullSupply(
        address positionManager,
        address token,
        bool tokenIsToken0,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (uint256 nftId) {
        uint256 supply = IERC20(token).balanceOf(address(this));
        IERC20(token).forceApprove(positionManager, supply);
        (nftId,,,) = INonfungiblePositionManager(positionManager).mint(
            INonfungiblePositionManager.MintParams({
                token0: tokenIsToken0 ? token : address(whype),
                token1: tokenIsToken0 ? address(whype) : token,
                fee: POOL_FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: tokenIsToken0 ? supply : 0,
                amount1Desired: tokenIsToken0 ? 0 : supply,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(locker),
                deadline: block.timestamp
            })
        );
    }

    function _correctPool(address pool, uint160 target, bool tokenIsToken0, address token) internal {
        (uint160 current,,,,,,) = IUniswapV3PoolState(pool).slot0();
        bool zeroForOne = current > target;
        bool inputIsToken = zeroForOne == tokenIsToken0;

        int256 amountIn;
        if (inputIsToken) {
            uint256 cap = TOTAL_SUPPLY * CORRECTION_MAX_SUPPLY_BPS / BPS;
            uint256 bal = IERC20(token).balanceOf(address(this));
            amountIn = int256(bal < cap ? bal : cap);
        } else {
            amountIn = int256(1e18);
        }

        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        expectedPool = pool;
        IUniswapV3PoolState(pool).swap(address(this), zeroForOne, amountIn, target, abi.encode(token, tokenIsToken0));
        expectedPool = address(0);

        uint256 sold = tokenBefore - IERC20(token).balanceOf(address(this));
        uint256 gained = whype.balanceOf(address(this));
        (uint160 reached,,,,,,) = IUniswapV3PoolState(pool).slot0();
        emit PoolCorrected(token, pool, current, target, reached, sold, gained);

        if (gained > 0) whype.safeTransfer(treasury, gained);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != expectedPool || msg.sender == address(0)) revert BadCallback();
        (address token, bool tokenIsToken0) = abi.decode(data, (address, bool));
        address token0 = tokenIsToken0 ? token : address(whype);
        address token1 = tokenIsToken0 ? address(whype) : token;
        if (amount0Delta > 0) IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    function _runSeedBuys(address token, SeedBuy[] calldata seedBuys, uint256 seedTotal, address swapRouter)
        internal
    {

        uint256 quoteBefore = whype.balanceOf(address(this));
        IWHYPE(address(whype)).deposit{value: seedTotal}();
        uint256 credited = whype.balanceOf(address(this)) - quoteBefore;
        if (credited < seedTotal) revert QuoteMissing(credited, seedTotal);

        whype.forceApprove(swapRouter, seedTotal);
        for (uint256 i = 0; i < seedBuys.length; i++) {
            uint256 amountOut = ISwapRouter(swapRouter).exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(whype),
                    tokenOut: token,
                    fee: POOL_FEE,
                    recipient: seedBuys[i].recipient,
                    deadline: block.timestamp,
                    amountIn: seedBuys[i].amountIn,
                    amountOutMinimum: seedBuys[i].minOut,
                    sqrtPriceLimitX96: 0
                })
            );
            emit SeedBuyFilled(token, seedBuys[i].recipient, seedBuys[i].amountIn, amountOut);
        }

        whype.forceApprove(swapRouter, 0);
    }

    function computeTokenAddress(
        string calldata name_,
        string calldata symbol_,
        string calldata metadata_,
        address deployer,
        bytes32 salt,
        bytes32 entropy
    ) external view returns (address) {
        bytes32 initHash = initCodeHash(name_, symbol_, metadata_, deployer);
        bytes32 create2Salt = keccak256(abi.encode(deployer, salt, entropy));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), create2Salt, initHash))))
        );
    }

    function initCodeHash(string calldata name_, string calldata symbol_, string calldata metadata_, address creator_)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                type(PearpadLaunchToken).creationCode, abi.encode(name_, symbol_, metadata_, creator_)
            )
        );
    }

    function feeSplit(uint256 total) public pure returns (uint256 toCreator, uint256 toTreasury) {
        toCreator = total * CREATOR_SHARE_BPS / BPS;
        toTreasury = total - toCreator;
    }

    function launchCost(uint256 seedTotalWhype) external pure returns (uint256) {
        return LAUNCH_FEE + seedTotalWhype;
    }

    function _startSqrtPriceX96(StartMcap p, bool tokenIsToken0) internal pure returns (uint160) {
        if (p == StartMcap.MCAP_50) return tokenIsToken0 ? SQRT_MCAP_50_T0 : SQRT_MCAP_50_T1;
        if (p == StartMcap.MCAP_100) return tokenIsToken0 ? SQRT_MCAP_100_T0 : SQRT_MCAP_100_T1;
        if (p == StartMcap.MCAP_250) return tokenIsToken0 ? SQRT_MCAP_250_T0 : SQRT_MCAP_250_T1;
        return tokenIsToken0 ? SQRT_MCAP_500_T0 : SQRT_MCAP_500_T1;
    }

    function _floorSpacing(int24 t, int24 spacing) internal pure returns (int24) {
        int24 q = t / spacing;
        if (t < 0 && t % spacing != 0) q -= 1;
        return q * spacing;
    }

    function _ceilSpacing(int24 t, int24 spacing) internal pure returns (int24) {
        int24 q = t / spacing;
        if (t > 0 && t % spacing != 0) q += 1;
        return q * spacing;
    }
}

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

interface ISwapRouterV1 {
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

interface IPositionManagerCollect {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
}

interface ITreasuryLookup {
    function treasury() external view returns (address);
}

contract PearpadLocker is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Lock {
        address token;
        address creator;
        address positionManager;
        address swapRouter;
        uint256 nftId;
    }

    uint24 public constant POOL_FEE = 10_000;
    uint256 public constant CREATOR_SHARE_BPS = 6_000;
    uint256 internal constant BPS = 10_000;

    IERC20 public immutable whype;
    address public immutable launcher;

    mapping(uint256 => Lock) public locks;
    mapping(address => uint256) public lockOf;

    error NotLauncher();
    error AlreadyRegistered(uint256 launchId);
    error UnknownLock(uint256 launchId);

    event Registered(uint256 indexed launchId, address indexed token, address indexed creator, uint256 nftId);
    event Collected(
        uint256 indexed launchId,
        address indexed token,
        address caller,
        uint256 tokenFees,
        uint256 quoteTotal,
        uint256 toCreator,
        uint256 toTreasury
    );

    constructor(IERC20 whype_) {
        whype = whype_;
        launcher = msg.sender;
    }

    function register(
        uint256 launchId,
        uint256 nftId,
        address token,
        address creator,
        address positionManager,
        address swapRouter
    ) external {
        if (msg.sender != launcher) revert NotLauncher();
        if (locks[launchId].token != address(0)) revert AlreadyRegistered(launchId);
        locks[launchId] = Lock({
            token: token, creator: creator, positionManager: positionManager, swapRouter: swapRouter, nftId: nftId
        });
        lockOf[token] = launchId;
        emit Registered(launchId, token, creator, nftId);
    }

    function collect(uint256 launchId) external nonReentrant returns (uint256 toCreator, uint256 toTreasury) {
        Lock memory l = locks[launchId];
        if (l.token == address(0)) revert UnknownLock(launchId);

        IPositionManagerCollect(l.positionManager).collect(
            IPositionManagerCollect.CollectParams({
                tokenId: l.nftId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        uint256 tokenBal = IERC20(l.token).balanceOf(address(this));
        if (tokenBal > 0) {
            IERC20(l.token).forceApprove(l.swapRouter, tokenBal);
            ISwapRouterV1(l.swapRouter).exactInputSingle(
                ISwapRouterV1.ExactInputSingleParams({
                    tokenIn: l.token,
                    tokenOut: address(whype),
                    fee: POOL_FEE,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: tokenBal,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            IERC20(l.token).forceApprove(l.swapRouter, 0);
        }

        uint256 quoteTotal = whype.balanceOf(address(this));
        if (quoteTotal > 0) {
            toCreator = quoteTotal * CREATOR_SHARE_BPS / BPS;
            toTreasury = quoteTotal - toCreator;
            if (toCreator > 0) whype.safeTransfer(l.creator, toCreator);
            if (toTreasury > 0) whype.safeTransfer(ITreasuryLookup(launcher).treasury(), toTreasury);
        }

        emit Collected(launchId, l.token, msg.sender, tokenBal, quoteTotal, toCreator, toTreasury);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

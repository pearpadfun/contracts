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

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// SwapRouter02: exactInputSingle takes no deadline field.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface ICreatorLookup {
    function creatorOf(address token) external view returns (address);
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

/// @notice Permanently locked LP. Liquidity can never be withdrawn; only
/// earned trading fees are collectable.
contract PearpadLocker {
    uint256 public constant CREATOR_SHARE_BPS = 6000;
    uint24 public constant POOL_FEE = 10_000;

    IPositionManagerCollect public immutable positionManager;
    ISwapRouter public immutable swapRouter;
    address public immutable usdt0; // ERC-20 side of the native gas token
    address public treasury;
    address public immutable factory;

    mapping(uint256 => address) public positionToken;
    mapping(address => uint256) public positionOf;

    constructor(IPositionManagerCollect positionManager_, ISwapRouter swapRouter_, address usdt0_, address treasury_) {
        positionManager = positionManager_;
        swapRouter = swapRouter_;
        usdt0 = usdt0_;
        treasury = treasury_;
        factory = msg.sender;
    }

    event TreasuryChanged(address indexed newTreasury);

    function setTreasury(address newTreasury) external {
        require(msg.sender == treasury, "not treasury");
        require(newTreasury != address(0), "zero treasury");
        treasury = newTreasury;
        emit TreasuryChanged(newTreasury);
    }

    function register(uint256 tokenId, address token) external {
        require(msg.sender == factory, "not factory");
        positionToken[tokenId] = token;
        positionOf[token] = tokenId;
    }

    // restricted callers: an open zero-floor collect would be sandwichable
    function collect(uint256 tokenId, uint256 minUsdtOut) external returns (uint256 usdtAmount, uint256 tokenAmount) {
        address token = positionToken[tokenId];
        require(token != address(0), "unknown position");
        address creator = ICreatorLookup(factory).creatorOf(token);
        require(msg.sender == creator || msg.sender == treasury, "not authorized");

        (uint256 amount0, uint256 amount1) = positionManager.collect(
            IPositionManagerCollect.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        (usdtAmount, tokenAmount) = token < usdt0 ? (amount1, amount0) : (amount0, amount1);

        uint256 creatorUsdt = usdtAmount * CREATOR_SHARE_BPS / 10_000;
        uint256 creatorToken = tokenAmount * CREATOR_SHARE_BPS / 10_000;
        if (creatorUsdt > 0) IERC20(usdt0).transfer(creator, creatorUsdt);
        if (creatorToken > 0) IERC20(token).transfer(creator, creatorToken);

        uint256 treasuryToken = tokenAmount - creatorToken;
        if (treasuryToken > 0) {
            IERC20(token).approve(address(swapRouter), treasuryToken);
            swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: usdt0,
                    fee: POOL_FEE,
                    recipient: treasury,
                    amountIn: treasuryToken,
                    amountOutMinimum: minUsdtOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }
        uint256 treasuryUsdt = usdtAmount - creatorUsdt;
        if (treasuryUsdt > 0) IERC20(usdt0).transfer(treasury, treasuryUsdt);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

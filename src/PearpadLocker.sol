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

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

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
    function creatorShareOf(address token) external view returns (uint16);
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

contract PearpadLocker {
    using SafeERC20 for IERC20;

    struct Position {
        address token;
        uint16 creatorShareBps;
    }

    IPositionManagerCollect public positionManager;
    ISwapRouter public swapRouter;
    address public immutable usdt0;
    address public treasury;

    address public immutable factory;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256) public positionOf;

    event TreasuryChanged(address indexed newTreasury);
    event Registered(uint256 indexed tokenId, address indexed token);
    event Collected(uint256 indexed tokenId, address indexed token, address caller, uint256 usdtOut, uint256 creatorCut);
    event AddressSet(bytes32 indexed key, address value);

    modifier onlyTreasury() {
        require(msg.sender == treasury, "not treasury");
        _;
    }

    uint24 public constant POOL_FEE = 10_000;

    constructor(IPositionManagerCollect positionManager_, ISwapRouter swapRouter_, address usdt0_, address treasury_) {
        require(usdt0_ != address(0) && treasury_ != address(0), "zero address");
        positionManager = positionManager_;
        swapRouter = swapRouter_;
        usdt0 = usdt0_;
        treasury = treasury_;
        factory = msg.sender;
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        require(newTreasury != address(0), "zero treasury");
        treasury = newTreasury;
        emit TreasuryChanged(newTreasury);
    }

    function setAddress(bytes32 key, address value) external onlyTreasury {
        require(value != address(0), "zero address");
        if (key == "positionManager") positionManager = IPositionManagerCollect(value);
        else if (key == "swapRouter") swapRouter = ISwapRouter(value);
        else revert("bad key");
        emit AddressSet(key, value);
    }

    function register(uint256 tokenId, address token) external {
        require(msg.sender == factory, "not factory");
        require(positions[tokenId].token == address(0), "registered");
        positions[tokenId] = Position({token: token, creatorShareBps: ICreatorLookup(factory).creatorShareOf(token)});
        positionOf[token] = tokenId;
        emit Registered(tokenId, token);
    }

    function collect(uint256 tokenId) external returns (uint256 usdtAmount) {
        Position memory p = positions[tokenId];
        require(p.token != address(0), "unknown position");
        address token = p.token;
        address creator = ICreatorLookup(factory).creatorOf(token);
        require(creator != address(0), "no creator");

        (uint256 amount0, uint256 amount1) = positionManager.collect(
            IPositionManagerCollect.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        uint256 tokenAmount;
        (usdtAmount, tokenAmount) = token < usdt0 ? (amount1, amount0) : (amount0, amount1);

        if (tokenAmount > 0) {
            IERC20(token).forceApprove(address(swapRouter), tokenAmount);
            usdtAmount += swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: usdt0,
                    fee: POOL_FEE,
                    recipient: address(this),
                    amountIn: tokenAmount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            IERC20(token).forceApprove(address(swapRouter), 0);
        }

        uint256 creatorUsdt = usdtAmount * p.creatorShareBps / 10_000;
        if (creatorUsdt > 0) IERC20(usdt0).safeTransfer(creator, creatorUsdt);
        uint256 treasuryUsdt = usdtAmount - creatorUsdt;
        if (treasuryUsdt > 0) IERC20(usdt0).safeTransfer(treasury, treasuryUsdt);
        emit Collected(tokenId, token, msg.sender, usdtAmount, creatorUsdt);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

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
import {ISwapRouter} from "./PearpadLocker.sol";

contract PearpadRouter {
    using SafeERC20 for IERC20;

    uint24 public constant POOL_FEE = 10_000;

    IERC20 public immutable usdt0;
    ISwapRouter public swapRouter;
    address public treasury;
    uint256 public bps;

    uint256 public feesOwed;

    event TreasuryChanged(address indexed newTreasury);
    event BpsChanged(uint256 bps);
    event AddressSet(bytes32 indexed key, address value);

    modifier onlyTreasury() {
        require(msg.sender == treasury, "not treasury");
        _;
    }

    constructor(IERC20 usdt0_, ISwapRouter swapRouter_, address treasury_, uint256 bps_) {
        require(treasury_ != address(0), "zero treasury");
        usdt0 = usdt0_;
        swapRouter = swapRouter_;
        treasury = treasury_;
        _setBps(bps_);
    }

    function _setBps(uint256 bps_) internal {
        require(bps_ <= 1_000, "bps too high");
        bps = bps_;
        emit BpsChanged(bps_);
    }

    function setBps(uint256 bps_) external onlyTreasury {
        _setBps(bps_);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        require(newTreasury != address(0), "zero treasury");
        treasury = newTreasury;
        emit TreasuryChanged(newTreasury);
    }

    function setAddress(bytes32 key, address value) external onlyTreasury {
        require(value != address(0), "zero address");
        if (key == "swapRouter") swapRouter = ISwapRouter(value);
        else revert("bad key");
        emit AddressSet(key, value);
    }

    function claimFees() external onlyTreasury {
        uint256 amount = feesOwed;
        feesOwed = 0;
        _send(msg.sender, amount);
    }

    function buy(address token, uint256 amountOutMin) external payable returns (uint256 amountOut) {
        uint256 amountIn = (msg.value - msg.value * bps / 10_000) / 1e12;
        feesOwed += msg.value - amountIn * 1e12;

        usdt0.forceApprove(address(swapRouter), amountIn);
        amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(usdt0),
                tokenOut: token,
                fee: POOL_FEE,
                recipient: msg.sender,
                amountIn: amountIn,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function sell(address token, uint256 amountIn, uint256 amountOutMin) external returns (uint256 ethOut) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(token).forceApprove(address(swapRouter), amountIn);

        uint256 usdtOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(usdt0),
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        uint256 grossOut = usdtOut * 1e12;
        ethOut = grossOut - grossOut * bps / 10_000;
        require(ethOut >= amountOutMin, "slippage");
        feesOwed += grossOut - ethOut;
        _send(msg.sender, ethOut);
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "send failed");
    }
}

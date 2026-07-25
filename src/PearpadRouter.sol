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
import {ISwapRouter} from "./PearpadLocker.sol";

/// @notice Pearpad swap router: 1% platform fee, then the pool.
/// On Stable, USDT0 is both the native gas token (18 dec) and an ERC-20 (6 dec)
/// on the same balance — no wrapping. Pools pair against the ERC-20 side.
contract PearpadRouter {
    uint256 public constant FEE_BPS = 100;
    uint24 public constant POOL_FEE = 10_000;

    IERC20 public immutable usdt0;
    ISwapRouter public immutable swapRouter;
    address public treasury;

    uint256 public feesOwed; // claimable native USDT0, treasury only

    event TreasuryChanged(address indexed newTreasury);

    constructor(IERC20 usdt0_, ISwapRouter swapRouter_, address treasury_) {
        usdt0 = usdt0_;
        swapRouter = swapRouter_;
        treasury = treasury_;
    }

    function setTreasury(address newTreasury) external {
        require(msg.sender == treasury, "not treasury");
        require(newTreasury != address(0), "zero treasury");
        treasury = newTreasury;
        emit TreasuryChanged(newTreasury);
    }

    function claimFees() external {
        require(msg.sender == treasury, "not treasury");
        uint256 amount = feesOwed;
        feesOwed = 0;
        _send(msg.sender, amount);
    }

    function buy(address token, uint256 amountOutMin) external payable returns (uint256 amountOut) {
        uint256 amountIn = (msg.value - msg.value * FEE_BPS / 10_000) / 1e12; // 6-dec swap size
        feesOwed += msg.value - amountIn * 1e12; // fee + sub-1e-6 dust, keeps balance == accounting

        usdt0.approve(address(swapRouter), amountIn);
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
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);
        IERC20(token).approve(address(swapRouter), amountIn);

        // USDT0 received as ERC-20 credits this contract's native balance — payable straight out
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
        uint256 fee = grossOut * FEE_BPS / 10_000;
        ethOut = grossOut - fee;
        require(ethOut >= amountOutMin, "slippage");
        feesOwed += fee;
        _send(msg.sender, ethOut);
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "send failed");
    }
}

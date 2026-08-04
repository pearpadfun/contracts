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

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract PearpadToken is ERC20, ERC20Burnable {
    string public constant VERSION = "pear-v3";

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    address public immutable platform;
    address public immutable creator;

    string public metadata;

    constructor(string memory name_, string memory symbol_, string memory metadata_, address creator_, uint256 supply)
        ERC20(name_, symbol_)
    {
        require(creator_ != address(0), "zero creator");
        platform = msg.sender;
        creator = creator_;
        metadata = metadata_;
        _mint(msg.sender, supply);
        emit OwnershipTransferred(address(0), msg.sender);
        emit OwnershipTransferred(msg.sender, address(0));
    }

    function tokenURI() external view returns (string memory) {
        return metadata;
    }

    function owner() public pure returns (address) {
        return address(0);
    }
}

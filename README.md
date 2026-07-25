<p align="center">
  <img src="logo.png" alt="pearpad" width="120">
</p>

<h1 align="center">pearpad-contracts</h1>

<p align="center"><strong>The on-chain launchpad behind <a href="https://pearpad.fun">pearpad.fun</a>: bonding curve to Uniswap v3, all in Solidity.</strong></p>

<p align="center">
  <img src="https://img.shields.io/badge/solidity-%5E0.8.24-25a17b" alt="solidity">
  <img src="https://img.shields.io/badge/chain-Stable%20988-25a17b" alt="chain">
  <img src="https://img.shields.io/badge/verified-Stablescan-2fc492" alt="verified">
  <img src="https://img.shields.io/badge/license-MIT-2fc492" alt="license">
</p>

Solidity source for [pearpad.fun](https://pearpad.fun), a meme-token launchpad with an on-chain bonding curve and automatic Uniswap v3 graduation, deployed on Stable Mainnet (chain 988).

## Deployed

All live on chain 988 and verified on [Stablescan](https://stablescan.xyz).

| Contract | Address |
|---|---|
| PearpadFactory | `0xF2fe7D1eC701f69aEc294CA625d8520D4C2340c4` |
| PearpadLocker  | `0x9158045B28b72700D2E9652F0A7952d88C7294cD` |
| PearpadRouter  | `0xf403be0A82d6400E5cb018A89FDeC6201AF02d98` |

`PearpadToken` is deployed per launch by the factory.

## Contracts

- **PearpadFactory**: launches tokens, runs the bonding curve, migrates to Uniswap v3 at target.
- **PearpadToken**: the ERC-20 minted per launch.
- **PearpadRouter**: buy/sell entrypoint over the curve.
- **PearpadLocker**: locks graduated LP.

## Build

Dependencies are not vendored. Install them with [Foundry](https://getfoundry.sh):

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.6.1 foundry-rs/forge-std
forge build
```

## License

MIT

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
| PearpadFactory | `0x341d613Cd110c602713E23cFE8826Aed54fa026F` |
| PearpadLocker  | `0xb3a22d7d9617fF151415E228Ce10d5D42D0fc5Ee` |
| PearpadRouter  | `0x19b824Bf30424f89D9d8BEC940232234fE79226A` |

`PearpadToken` is deployed per launch by the factory. `src/` here matches the
verified bytecode at these addresses.

## Contracts

- **PearpadFactory**: launches tokens, runs the bonding curve, migrates to Uniswap v3 at target.
- **PearpadToken**: the ERC-20 minted per launch.
- **PearpadRouter**: buy/sell entrypoint over the curve.
- **PearpadLocker**: locks graduated LP.

## Integration

Building on top of pearpad? See **[INTEGRATION.md](INTEGRATION.md)** — the full buy/sell guide (two trading phases, quote math, viem/ethers examples).

Contract ABIs live in [`abi/`](abi/), ready for viem/ethers:

- [`abi/PearpadFactory.json`](abi/PearpadFactory.json) — launch + bonding-curve trading
- [`abi/PearpadRouter.json`](abi/PearpadRouter.json) — post-graduation swaps
- [`abi/PearpadToken.json`](abi/PearpadToken.json) — the per-launch ERC-20
- [`abi/PearpadLocker.json`](abi/PearpadLocker.json) — locked LP

## Build

Dependencies are not vendored. Install them with [Foundry](https://getfoundry.sh):

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.6.1 foundry-rs/forge-std
forge build
```

## License

MIT

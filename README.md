<p align="center">
  <img src="logo.png" alt="pearpad" width="120">
</p>

<h1 align="center">pearpad-contracts</h1>

<p align="center"><strong>The on-chain launchpads behind <a href="https://pearpad.fun">pearpad.fun</a>, in Solidity: a bonding curve on Stable, a direct-to-market launcher on HyperEVM.</strong></p>

<p align="center">
  <img src="https://img.shields.io/badge/solidity-%5E0.8.24-25a17b" alt="solidity">
  <img src="https://img.shields.io/badge/chains-Stable%20988%20%7C%20HyperEVM%20999-25a17b" alt="chains">
  <img src="https://img.shields.io/badge/verified-on%20chain-2fc492" alt="verified">
  <img src="https://img.shields.io/badge/license-MIT-2fc492" alt="license">
</p>

Solidity source for [pearpad.fun](https://pearpad.fun). Two launch models, one per chain. They are separate systems in separate directories, not one codebase with a chain flag.

| | [`stable-988/`](stable-988/) | [`hyperevm-999/`](hyperevm-999/) |
|---|---|---|
| Chain | Stable Mainnet (988) | HyperEVM (999) |
| Model | bonding curve, graduates to Uniswap v3 | direct to market: whole supply into a v3 range at launch |
| Quote asset | USDT0 | WHYPE |
| Explorer | [Stablescan](https://stablescan.xyz) | [hyperevmscan](https://hyperevmscan.io) |
| Solidity | `evm_version = "osaka"` | `evm_version = "cancun"` |

⚠️ **The `evm_version` pins differ.** Each directory carries its own
`foundry.toml`. Building with the wrong one produces different bytecode and
will not reproduce the verified deployment.

## Deployed

### Stable, chain 988 (verified on [Stablescan](https://stablescan.xyz))

| Contract | Address |
|---|---|
| PearpadFactory | `0x341d613Cd110c602713E23cFE8826Aed54fa026F` |
| PearpadLocker  | `0xb3a22d7d9617fF151415E228Ce10d5D42D0fc5Ee` |
| PearpadRouter  | `0x19b824Bf30424f89D9d8BEC940232234fE79226A` |

- **PearpadFactory**: launches tokens, runs the bonding curve, migrates to Uniswap v3 at target.
- **PearpadToken**: the ERC-20 minted per launch.
- **PearpadRouter**: buy/sell entrypoint over the curve.
- **PearpadLocker**: locks graduated LP.

### HyperEVM, chain 999 (verified on [hyperevmscan](https://hyperevmscan.io))

| Contract | Address |
|---|---|
| PearpadLauncher | `0x4e1408e143153Caa6D77FBb571452A26f94854cC` |

- **PearpadLauncher**: one transaction deploys a fixed-supply token and mints
  the whole supply as a single-sided Uniswap v3 range just above spot. The
  canonical pool is the market from block one. The contract holds no reserve.
- **PearpadLaunchToken**: the ERC-20 minted per launch.

Venues are a registry, snapshotted per launch: venue 0 is PRJX V3, venue 1 is
HyperSwap V3.

Each launchpad deploys its own per-launch token. The source in each directory
matches the verified bytecode at these addresses.

## Integration

Building on top of pearpad starts with **[INTEGRATION.md](INTEGRATION.md)**, the full buy/sell guide: two trading phases, quote math, viem and ethers examples.

INTEGRATION.md covers chain 988. Contract ABIs live under each chain directory,
ready for viem or ethers:

- [`stable-988/abi/PearpadFactory.json`](stable-988/abi/PearpadFactory.json): launch and bonding-curve trading
- [`stable-988/abi/PearpadRouter.json`](stable-988/abi/PearpadRouter.json): post-graduation swaps
- [`stable-988/abi/PearpadToken.json`](stable-988/abi/PearpadToken.json): the per-launch ERC-20
- [`stable-988/abi/PearpadLocker.json`](stable-988/abi/PearpadLocker.json): locked LP
- [`hyperevm-999/abi/PearpadLauncher.json`](hyperevm-999/abi/PearpadLauncher.json): launch, fee quote, venue registry, fee collection
- [`hyperevm-999/abi/PearpadLaunchToken.json`](hyperevm-999/abi/PearpadLaunchToken.json): the per-launch ERC-20

On HyperEVM a launch costs roughly 5.85M gas against a 3M fast-block limit, so
the sending account needs big blocks enabled. That is a HyperCore setting on the
account, not a transaction field.

## Build

Dependencies are not vendored. Install them with [Foundry](https://getfoundry.sh):

```bash
cd stable-988    # or: cd hyperevm-999
forge install OpenZeppelin/openzeppelin-contracts@v5.6.1 foundry-rs/forge-std
forge build
```

Build from inside a chain directory, not the repo root. Each one pins its own
`evm_version`, and that pin is what makes the bytecode reproduce.

## License

MIT

# pearpad-contracts

Solidity source for [pearpad.fun](https://pearpad.fun), a meme-token launchpad
with an on-chain bonding curve and automatic Uniswap v3 graduation, deployed on
Stable Mainnet (chain 988).

## Deployed (chain 988, verified on [Stablescan](https://stablescan.xyz))

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

```
forge install OpenZeppelin/openzeppelin-contracts@v5.6.1 foundry-rs/forge-std
forge build
```

## License

MIT

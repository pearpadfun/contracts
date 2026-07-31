# Security policy

These contracts are live on Stable Mainnet (chain 988) and hold real funds.

**Report a vulnerability: security@pearpad.fun**

Report privately first. Do not open a public issue, and do not demonstrate a
finding against live user funds.

## What to include

- Which contract and function, ideally with a line reference.
- How to reproduce it. A Foundry test is ideal; a transaction hash or a clear
  description is fine.
- What an attacker gains: funds, another user's position, or admin control.

A three-line email with a working reproduction beats a formatted report
without one.

## What happens next

| When | What |
|---|---|
| Within 72 hours | We acknowledge and tell you whether we reproduced it. |
| Within 7 days | Critical and high-severity issues are fixed or mitigated. |
| After the fix | We confirm with you and credit you if you want credit. |

Coordinated disclosure: we publish after the fix ships, or 90 days after your
report, whichever comes first.

## Scope

In scope: the deployed V3 contracts and this source.

| Contract | Address |
|---|---|
| PearpadFactory | `0x341d613Cd110c602713E23cFE8826Aed54fa026F` |
| PearpadLocker  | `0xb3a22d7d9617fF151415E228Ce10d5D42D0fc5Ee` |
| PearpadRouter  | `0x19b824Bf30424f89D9d8BEC940232234fE79226A` |

Plus every `PearpadToken` the factory deploys. All are verified on
[Stablescan](https://stablescan.xyz). Check the verified source before
reporting against a local build, since compiler settings affect bytecode.

Out of scope:

- The deprecated V1 launchpad and the abandoned July 2026 test deployment.
  V1 still holds redeemable curve reserves for its holders but is unsupported.
- Uniswap v3, Multicall3, USDT0, and the Stable chain itself.
- Gas-optimization suggestions and style preferences. Send those as a normal
  issue or PR. They are welcome, they just are not security reports.

## Testing

Test against a fork, not mainnet:

```bash
forge test --fork-url https://rpc.stable.xyz
```

Use your own wallets and your own funds if you must touch mainnet, and stop at
proof of concept: move one wei, not the balance. Stay inside these rules and we
will not pursue or support legal action against you for your research.

## Rewards

There is no formal bounty program today. We may reward significant findings at
our discretion and will credit you publicly if you want it.

## Known design decisions

We chose these deliberately. No need to report them:

- **The treasury is the sole admin.** It sets the launch fee, can pause
  launches, and can change the default curve configuration. Each token
  snapshots its configuration at launch, so changes never apply retroactively
  to a live curve.
- **`usdt0` is immutable by design.** It denominates every live curve reserve;
  making it settable would strand funds.
- **Liquidity is locked forever** in `PearpadLocker` at graduation. There is no
  withdrawal path, only fee collection.
- **Tokens have no owner, mint, pause, or blacklist functions** after launch.

## Contact

security@pearpad.fun

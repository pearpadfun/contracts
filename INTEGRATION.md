# Pearpad integration guide: swapping

For agents implementing buy/sell against Pearpad on **Stable mainnet (chain id 988)**, RPC `https://rpc.stable.xyz`.

## Deployed contracts

| Contract | Address | Role |
|---|---|---|
| PearpadFactory | `0x341d613Cd110c602713E23cFE8826Aed54fa026F` | Launches tokens, bonding-curve trading pre-migration |
| PearpadRouter | `0x19b824Bf30424f89D9d8BEC940232234fE79226A` | Swaps post-migration (wraps Uniswap V3) |
| PearpadLocker | `0xb3a22d7d9617fF151415E228Ce10d5D42D0fc5Ee` | Holds locked LP; not needed for swapping |
| USDT0 | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` | Dual-role: native gas token (18 dec) AND ERC-20 (6 dec) on the same balance |

ABIs: inlined at the bottom of this file (plain arrays, ready for viem/ethers).

## Key concept: two trading phases

Every token launches on a bonding curve inside the **Factory**. When the curve's real reserve hits the token's target (per-token config, current default 6,375 USDT0), it auto-migrates to a Uniswap V3 pool at the curve's closing price and curve trading stops. The pool's fee tier is `POOL_FEE` on the Factory and the Router, which you need to derive the pool address. After that, all swaps go through the **Router**.

Every token's terms are frozen at launch. Read `factory.configOf(token)` → `(virtualUsdt, targetUsdt, totalSupply, virtualTokens, creatorBps, treasuryBps, lpCreatorBps)`; the same struct rides on its `Launched` event and on every `/api/tokens` row as `cfg`.

Phase check: `factory.curves(token)` returns `(ethReserve, tokenReserve, creator, migrated, cfg)`.
- `creator == 0x0` → not a pearpad token
- `migrated == false` → trade on Factory
- `migrated == true` → trade on Router

The `Migrated(token, pool, tokenId)` event fires at the flip.

## Decimals

All native-value amounts (msg.value, curve reserves, quotes, payouts) are **18-decimal USDT0**. Pearpad tokens are 18 decimals. Only the ERC-20 side of USDT0 (inside V3 pools) is 6 decimals, and the Router converts internally, so you never handle 6-dec amounts.

## Phase 1: bonding curve (Factory)

```solidity
// quotes (view)
getTokensOut(address token, uint256 ethIn) → uint256   // buy quote, ethIn is post-fee
getEthOut(address token, uint256 tokensIn) → uint256   // sell quote, pre-fee

// trade
buy(address token, uint256 minTokensOut) payable → uint256 tokensOut  // send USDT0 as msg.value
sell(address token, uint256 tokensIn, uint256 minEthOut) → uint256 ethOut  // approve factory for tokensIn first
```

- Per-trade bps are per token: `bps = cfg.creatorBps + cfg.treasuryBps`. Read them from the token's config; never hardcode them, since each token carries its own and they are fixed at its launch.
- `buy` quote for UI: `getTokensOut(token, msg.value * 10000 / (10000 + bps))` (bps come off msg.value first).
- `sell` payout for UI: `gross = getEthOut(token, tokensIn)`, user receives `gross - gross*bps/10000`.
- Buys that would push the reserve past the token's target are capped and the excess refunded; a buy that lands exactly on target triggers migration in the same tx, which costs more gas, so don't set tight gas limits.
- Events for indexing: `Launched(token, creator, metadata, cfg)`, `Bought(token, buyer, ethIn, tokensOut, ethReserve, tokenReserve)`, `Sold(...)`, `Migrated`.
- Launching: `launch(name, symbol, metadata, maxFee)` payable. Always read `launchFee()`, which may change at any time, and pass it as the `maxFee` guard. Any value beyond the fee executes the creator's first buy atomically.

## Phase 2: migrated (Router)

```solidity
buy(address token, uint256 amountOutMin) payable → uint256 amountOut   // send USDT0 as msg.value
sell(address token, uint256 amountIn, uint256 amountOutMin) → uint256 ethOut  // approve router for amountIn first
```

- The router takes its own bps on top of the pool's fee tier. Read them with `router.bps()` and `router.POOL_FEE()`.
- `amountOutMin` on buy is in token units; on sell it's 18-dec native USDT0.
- Quotes: no on-chain quoter wrapper exists. Use the V3 pool directly (pool address from the `Migrated` event, or derive via the position manager factory), or eth_call-simulate the swap. Remember to knock the router's `bps()` off msg.value before quoting the pool leg.

## Creator fees

```solidity
collectFees(address token)   // permissionless, on the Factory
```

One call settles a token's outstanding fees, before or after migration: it pays the
token's creator and the treasury whatever the factory owes them, and once the token
has migrated it also collects the locked LP position's accrued fees. Recipients are
fixed by the contract. The caller supplies only the token address and receives
nothing, so anyone (a bot, a UI, the creator) can trigger it.

`feesOwed(address)` reads what the factory currently owes an address. A creator can
also pull their own balance directly with `claimFees()`.

## Approvals

- Curve sell: `token.approve(factory, amount)`
- Router sell: `token.approve(router, amount)`
- Buys never need approval (native value in).

## Implementation examples (viem)

```ts
import { createPublicClient, createWalletClient, custom, http, defineChain, parseEther } from 'viem'

export const stable = defineChain({
  id: 988,
  name: 'Stable',
  nativeCurrency: { name: 'USDT0', symbol: 'USDT0', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.stable.xyz'] } },
})

const FACTORY = '0x341d613Cd110c602713E23cFE8826Aed54fa026F'
const ROUTER  = '0x19b824Bf30424f89D9d8BEC940232234fE79226A'

const pub = createPublicClient({ chain: stable, transport: http() })
const wallet = createWalletClient({ chain: stable, transport: custom(window.ethereum) })

// ---- phase detection ----
async function isMigrated(token) {
  const [, , creator, migrated] = await pub.readContract({
    address: FACTORY, abi: factoryAbi, functionName: 'curves', args: [token] })
  if (creator === '0x0000000000000000000000000000000000000000') throw new Error('not a pearpad token')
  return migrated
}

// ---- per-token bps: read from its config, never hardcode ----
async function curveBps(token) {
  const cfg = await pub.readContract({ address: FACTORY, abi: factoryAbi,
    functionName: 'configOf', args: [token] })
  return BigInt(cfg.creatorBps) + BigInt(cfg.treasuryBps)
}

// ---- curve buy (pre-migration): spend 5 USDT0 with 1% slippage ----
async function curveBuy(token, account) {
  const value = parseEther('5')
  const bps = await curveBps(token)
  const ethIn = (value * 10_000n) / (10_000n + bps)    // bps come off msg.value first
  const quote = await pub.readContract({ address: FACTORY, abi: factoryAbi,
    functionName: 'getTokensOut', args: [token, ethIn] })
  return wallet.writeContract({ address: FACTORY, abi: factoryAbi, functionName: 'buy',
    args: [token, (quote * 99n) / 100n], value, account })
}

// ---- curve sell (pre-migration) ----
async function curveSell(token, amount, account) {
  await wallet.writeContract({ address: token, abi: erc20Abi, functionName: 'approve',
    args: [FACTORY, amount], account })
  const bps = await curveBps(token)
  const gross = await pub.readContract({ address: FACTORY, abi: factoryAbi,
    functionName: 'getEthOut', args: [token, amount] })
  const net = gross - (gross * bps) / 10_000n          // quote is gross; you receive net
  return wallet.writeContract({ address: FACTORY, abi: factoryAbi, functionName: 'sell',
    args: [token, amount, (net * 99n) / 100n], account })
}

// ---- router buy (post-migration): simulate for the quote, then send ----
async function routerBuy(token, account) {
  const value = parseEther('5')
  const { result } = await pub.simulateContract({ address: ROUTER, abi: routerAbi,
    functionName: 'buy', args: [token, 0n], value, account })
  return wallet.writeContract({ address: ROUTER, abi: routerAbi, functionName: 'buy',
    args: [token, (result * 99n) / 100n], value, account })
}

// ---- router sell (post-migration) ----
async function routerSell(token, amount, account) {
  await wallet.writeContract({ address: token, abi: erc20Abi, functionName: 'approve',
    args: [ROUTER, amount], account })
  const { result } = await pub.simulateContract({ address: ROUTER, abi: routerAbi,
    functionName: 'sell', args: [token, amount, 0n], account })
  return wallet.writeContract({ address: ROUTER, abi: routerAbi, functionName: 'sell',
    args: [token, amount, (result * 99n) / 100n], account })
}

// ---- launch a token (fee = launchFee(); extra value = creator first buy) ----
async function launchToken(name, symbol, metadataUri, devBuy, account) {
  const fee = await pub.readContract({ address: FACTORY, abi: factoryAbi, functionName: 'launchFee' })
  return wallet.writeContract({ address: FACTORY, abi: factoryAbi, functionName: 'launch',
    args: [name, symbol, metadataUri, fee], value: fee + devBuy, account })
}
```

`factoryAbi` / `routerAbi` are the arrays in the ABI section below; `erc20Abi` ships with viem.

## ABIs (plain arrays, paste into viem/ethers)

### PearpadFactory
```json
[{"type": "constructor", "inputs": [{"name": "usdt0_", "type": "address", "internalType": "contract IERC20"}, {"name": "positionManager_", "type": "address", "internalType": "contract INonfungiblePositionManager"}, {"name": "swapRouter_", "type": "address", "internalType": "contract ISwapRouter"}, {"name": "treasury_", "type": "address", "internalType": "address"}, {"name": "cfg", "type": "tuple", "internalType": "struct PearpadFactory.Config", "components": [{"name": "virtualUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "targetUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "totalSupply", "type": "uint128", "internalType": "uint128"}, {"name": "virtualTokens", "type": "uint128", "internalType": "uint128"}, {"name": "creatorBps", "type": "uint16", "internalType": "uint16"}, {"name": "treasuryBps", "type": "uint16", "internalType": "uint16"}, {"name": "lpCreatorBps", "type": "uint16", "internalType": "uint16"}]}], "stateMutability": "nonpayable"}, {"type": "function", "name": "POOL_FEE", "inputs": [], "outputs": [{"name": "", "type": "uint24", "internalType": "uint24"}], "stateMutability": "view"}, {"type": "function", "name": "TUNING_TOLERANCE_BPS", "inputs": [], "outputs": [{"name": "", "type": "uint256", "internalType": "uint256"}], "stateMutability": "view"}, {"type": "function", "name": "buy", "inputs": [{"name": "token", "type": "address", "internalType": "address"}, {"name": "minTokensOut", "type": "uint256", "internalType": "uint256"}], "outputs": [{"name": "tokensOut", "type": "uint256", "internalType": "uint256"}], "stateMutability": "payable"}, {"type": "function", "name": "claimFees", "inputs": [], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "collectFees", "inputs": [{"name": "token", "type": "address", "internalType": "address"}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "configOf", "inputs": [{"name": "token", "type": "address", "internalType": "address"}], "outputs": [{"name": "", "type": "tuple", "internalType": "struct PearpadFactory.Config", "components": [{"name": "virtualUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "targetUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "totalSupply", "type": "uint128", "internalType": "uint128"}, {"name": "virtualTokens", "type": "uint128", "internalType": "uint128"}, {"name": "creatorBps", "type": "uint16", "internalType": "uint16"}, {"name": "treasuryBps", "type": "uint16", "internalType": "uint16"}, {"name": "lpCreatorBps", "type": "uint16", "internalType": "uint16"}]}], "stateMutability": "view"}, {"type": "function", "name": "creatorOf", "inputs": [{"name": "token", "type": "address", "internalType": "address"}], "outputs": [{"name": "", "type": "address", "internalType": "address"}], "stateMutability": "view"}, {"type": "function", "name": "creatorShareOf", "inputs": [{"name": "token", "type": "address", "internalType": "address"}], "outputs": [{"name": "", "type": "uint16", "internalType": "uint16"}], "stateMutability": "view"}, {"type": "function", "name": "curves", "inputs": [{"name": "", "type": "address", "internalType": "address"}], "outputs": [{"name": "ethReserve", "type": "uint256", "internalType": "uint256"}, {"name": "tokenReserve", "type": "uint256", "internalType": "uint256"}, {"name": "creator", "type": "address", "internalType": "address"}, {"name": "migrated", "type": "bool", "internalType": "bool"}, {"name": "cfg", "type": "tuple", "internalType": "struct PearpadFactory.Config", "components": [{"name": "virtualUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "targetUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "totalSupply", "type": "uint128", "internalType": "uint128"}, {"name": "virtualTokens", "type": "uint128", "internalType": "uint128"}, {"name": "creatorBps", "type": "uint16", "internalType": "uint16"}, {"name": "treasuryBps", "type": "uint16", "internalType": "uint16"}, {"name": "lpCreatorBps", "type": "uint16", "internalType": "uint16"}]}], "stateMutability": "view"}, {"type": "function", "name": "defaultConfig", "inputs": [], "outputs": [{"name": "virtualUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "targetUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "totalSupply", "type": "uint128", "internalType": "uint128"}, {"name": "virtualTokens", "type": "uint128", "internalType": "uint128"}, {"name": "creatorBps", "type": "uint16", "internalType": "uint16"}, {"name": "treasuryBps", "type": "uint16", "internalType": "uint16"}, {"name": "lpCreatorBps", "type": "uint16", "internalType": "uint16"}], "stateMutability": "view"}, {"type": "function", "name": "feesOwed", "inputs": [{"name": "", "type": "address", "internalType": "address"}], "outputs": [{"name": "", "type": "uint256", "internalType": "uint256"}], "stateMutability": "view"}, {"type": "function", "name": "getEthOut", "inputs": [{"name": "token", "type": "address", "internalType": "address"}, {"name": "tokensIn", "type": "uint256", "internalType": "uint256"}], "outputs": [{"name": "", "type": "uint256", "internalType": "uint256"}], "stateMutability": "view"}, {"type": "function", "name": "getTokensOut", "inputs": [{"name": "token", "type": "address", "internalType": "address"}, {"name": "ethIn", "type": "uint256", "internalType": "uint256"}], "outputs": [{"name": "", "type": "uint256", "internalType": "uint256"}], "stateMutability": "view"}, {"type": "function", "name": "launch", "inputs": [{"name": "name", "type": "string", "internalType": "string"}, {"name": "symbol", "type": "string", "internalType": "string"}, {"name": "metadata", "type": "string", "internalType": "string"}, {"name": "maxFee", "type": "uint256", "internalType": "uint256"}], "outputs": [{"name": "token", "type": "address", "internalType": "address"}], "stateMutability": "payable"}, {"type": "function", "name": "launchFee", "inputs": [], "outputs": [{"name": "", "type": "uint256", "internalType": "uint256"}], "stateMutability": "view"}, {"type": "function", "name": "lpLocker", "inputs": [], "outputs": [{"name": "", "type": "address", "internalType": "contract PearpadLocker"}], "stateMutability": "view"}, {"type": "function", "name": "paused", "inputs": [], "outputs": [{"name": "", "type": "bool", "internalType": "bool"}], "stateMutability": "view"}, {"type": "function", "name": "positionManager", "inputs": [], "outputs": [{"name": "", "type": "address", "internalType": "contract INonfungiblePositionManager"}], "stateMutability": "view"}, {"type": "function", "name": "sell", "inputs": [{"name": "token", "type": "address", "internalType": "address"}, {"name": "tokensIn", "type": "uint256", "internalType": "uint256"}, {"name": "minEthOut", "type": "uint256", "internalType": "uint256"}], "outputs": [{"name": "ethOut", "type": "uint256", "internalType": "uint256"}], "stateMutability": "nonpayable"}, {"type": "function", "name": "setAddress", "inputs": [{"name": "key", "type": "bytes32", "internalType": "bytes32"}, {"name": "value", "type": "address", "internalType": "address"}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "setCreator", "inputs": [{"name": "token", "type": "address", "internalType": "address"}, {"name": "newCreator", "type": "address", "internalType": "address"}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "setDefaultConfig", "inputs": [{"name": "cfg", "type": "tuple", "internalType": "struct PearpadFactory.Config", "components": [{"name": "virtualUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "targetUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "totalSupply", "type": "uint128", "internalType": "uint128"}, {"name": "virtualTokens", "type": "uint128", "internalType": "uint128"}, {"name": "creatorBps", "type": "uint16", "internalType": "uint16"}, {"name": "treasuryBps", "type": "uint16", "internalType": "uint16"}, {"name": "lpCreatorBps", "type": "uint16", "internalType": "uint16"}]}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "setLaunchFee", "inputs": [{"name": "newFee", "type": "uint256", "internalType": "uint256"}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "setPaused", "inputs": [{"name": "paused_", "type": "bool", "internalType": "bool"}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "setTreasury", "inputs": [{"name": "newTreasury", "type": "address", "internalType": "address"}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "swapRouter", "inputs": [], "outputs": [{"name": "", "type": "address", "internalType": "address"}], "stateMutability": "view"}, {"type": "function", "name": "treasury", "inputs": [], "outputs": [{"name": "", "type": "address", "internalType": "address"}], "stateMutability": "view"}, {"type": "function", "name": "tunedVirtualTokens", "inputs": [{"name": "virtualUsdt_", "type": "uint256", "internalType": "uint256"}, {"name": "targetUsdt_", "type": "uint256", "internalType": "uint256"}, {"name": "totalSupply_", "type": "uint256", "internalType": "uint256"}], "outputs": [{"name": "", "type": "uint256", "internalType": "uint256"}], "stateMutability": "pure"}, {"type": "function", "name": "uniswapV3SwapCallback", "inputs": [{"name": "amount0Delta", "type": "int256", "internalType": "int256"}, {"name": "amount1Delta", "type": "int256", "internalType": "int256"}, {"name": "data", "type": "bytes", "internalType": "bytes"}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "usdt0", "inputs": [], "outputs": [{"name": "", "type": "address", "internalType": "contract IERC20"}], "stateMutability": "view"}, {"type": "event", "name": "AddressSet", "inputs": [{"name": "key", "type": "bytes32", "indexed": true, "internalType": "bytes32"}, {"name": "value", "type": "address", "indexed": false, "internalType": "address"}], "anonymous": false}, {"type": "event", "name": "Bought", "inputs": [{"name": "token", "type": "address", "indexed": true, "internalType": "address"}, {"name": "buyer", "type": "address", "indexed": true, "internalType": "address"}, {"name": "ethIn", "type": "uint256", "indexed": false, "internalType": "uint256"}, {"name": "tokensOut", "type": "uint256", "indexed": false, "internalType": "uint256"}, {"name": "ethReserve", "type": "uint256", "indexed": false, "internalType": "uint256"}, {"name": "tokenReserve", "type": "uint256", "indexed": false, "internalType": "uint256"}], "anonymous": false}, {"type": "event", "name": "CreatorChanged", "inputs": [{"name": "token", "type": "address", "indexed": true, "internalType": "address"}, {"name": "newCreator", "type": "address", "indexed": true, "internalType": "address"}], "anonymous": false}, {"type": "event", "name": "DefaultConfigChanged", "inputs": [{"name": "cfg", "type": "tuple", "indexed": false, "internalType": "struct PearpadFactory.Config", "components": [{"name": "virtualUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "targetUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "totalSupply", "type": "uint128", "internalType": "uint128"}, {"name": "virtualTokens", "type": "uint128", "internalType": "uint128"}, {"name": "creatorBps", "type": "uint16", "internalType": "uint16"}, {"name": "treasuryBps", "type": "uint16", "internalType": "uint16"}, {"name": "lpCreatorBps", "type": "uint16", "internalType": "uint16"}]}], "anonymous": false}, {"type": "event", "name": "LaunchFeeChanged", "inputs": [{"name": "newFee", "type": "uint256", "indexed": false, "internalType": "uint256"}], "anonymous": false}, {"type": "event", "name": "Launched", "inputs": [{"name": "token", "type": "address", "indexed": true, "internalType": "address"}, {"name": "creator", "type": "address", "indexed": true, "internalType": "address"}, {"name": "metadata", "type": "string", "indexed": false, "internalType": "string"}, {"name": "cfg", "type": "tuple", "indexed": false, "internalType": "struct PearpadFactory.Config", "components": [{"name": "virtualUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "targetUsdt", "type": "uint128", "internalType": "uint128"}, {"name": "totalSupply", "type": "uint128", "internalType": "uint128"}, {"name": "virtualTokens", "type": "uint128", "internalType": "uint128"}, {"name": "creatorBps", "type": "uint16", "internalType": "uint16"}, {"name": "treasuryBps", "type": "uint16", "internalType": "uint16"}, {"name": "lpCreatorBps", "type": "uint16", "internalType": "uint16"}]}], "anonymous": false}, {"type": "event", "name": "Migrated", "inputs": [{"name": "token", "type": "address", "indexed": true, "internalType": "address"}, {"name": "pool", "type": "address", "indexed": false, "internalType": "address"}, {"name": "tokenId", "type": "uint256", "indexed": false, "internalType": "uint256"}], "anonymous": false}, {"type": "event", "name": "PausedSet", "inputs": [{"name": "paused", "type": "bool", "indexed": false, "internalType": "bool"}], "anonymous": false}, {"type": "event", "name": "Sold", "inputs": [{"name": "token", "type": "address", "indexed": true, "internalType": "address"}, {"name": "seller", "type": "address", "indexed": true, "internalType": "address"}, {"name": "tokensIn", "type": "uint256", "indexed": false, "internalType": "uint256"}, {"name": "ethOut", "type": "uint256", "indexed": false, "internalType": "uint256"}, {"name": "ethReserve", "type": "uint256", "indexed": false, "internalType": "uint256"}, {"name": "tokenReserve", "type": "uint256", "indexed": false, "internalType": "uint256"}], "anonymous": false}, {"type": "event", "name": "TreasuryChanged", "inputs": [{"name": "newTreasury", "type": "address", "indexed": true, "internalType": "address"}], "anonymous": false}, {"type": "error", "name": "SafeERC20FailedOperation", "inputs": [{"name": "token", "type": "address", "internalType": "address"}]}]
```

### PearpadRouter
```json
[{"type": "constructor", "inputs": [{"name": "usdt0_", "type": "address", "internalType": "contract IERC20"}, {"name": "swapRouter_", "type": "address", "internalType": "contract ISwapRouter"}, {"name": "treasury_", "type": "address", "internalType": "address"}, {"name": "bps_", "type": "uint256", "internalType": "uint256"}], "stateMutability": "nonpayable"}, {"type": "function", "name": "POOL_FEE", "inputs": [], "outputs": [{"name": "", "type": "uint24", "internalType": "uint24"}], "stateMutability": "view"}, {"type": "function", "name": "bps", "inputs": [], "outputs": [{"name": "", "type": "uint256", "internalType": "uint256"}], "stateMutability": "view"}, {"type": "function", "name": "buy", "inputs": [{"name": "token", "type": "address", "internalType": "address"}, {"name": "amountOutMin", "type": "uint256", "internalType": "uint256"}], "outputs": [{"name": "amountOut", "type": "uint256", "internalType": "uint256"}], "stateMutability": "payable"}, {"type": "function", "name": "claimFees", "inputs": [], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "feesOwed", "inputs": [], "outputs": [{"name": "", "type": "uint256", "internalType": "uint256"}], "stateMutability": "view"}, {"type": "function", "name": "sell", "inputs": [{"name": "token", "type": "address", "internalType": "address"}, {"name": "amountIn", "type": "uint256", "internalType": "uint256"}, {"name": "amountOutMin", "type": "uint256", "internalType": "uint256"}], "outputs": [{"name": "ethOut", "type": "uint256", "internalType": "uint256"}], "stateMutability": "nonpayable"}, {"type": "function", "name": "setAddress", "inputs": [{"name": "key", "type": "bytes32", "internalType": "bytes32"}, {"name": "value", "type": "address", "internalType": "address"}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "setBps", "inputs": [{"name": "bps_", "type": "uint256", "internalType": "uint256"}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "setTreasury", "inputs": [{"name": "newTreasury", "type": "address", "internalType": "address"}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "swapRouter", "inputs": [], "outputs": [{"name": "", "type": "address", "internalType": "contract ISwapRouter"}], "stateMutability": "view"}, {"type": "function", "name": "treasury", "inputs": [], "outputs": [{"name": "", "type": "address", "internalType": "address"}], "stateMutability": "view"}, {"type": "function", "name": "usdt0", "inputs": [], "outputs": [{"name": "", "type": "address", "internalType": "contract IERC20"}], "stateMutability": "view"}, {"type": "event", "name": "AddressSet", "inputs": [{"name": "key", "type": "bytes32", "indexed": true, "internalType": "bytes32"}, {"name": "value", "type": "address", "indexed": false, "internalType": "address"}], "anonymous": false}, {"type": "event", "name": "BpsChanged", "inputs": [{"name": "bps", "type": "uint256", "indexed": false, "internalType": "uint256"}], "anonymous": false}, {"type": "event", "name": "TreasuryChanged", "inputs": [{"name": "newTreasury", "type": "address", "indexed": true, "internalType": "address"}], "anonymous": false}, {"type": "error", "name": "SafeERC20FailedOperation", "inputs": [{"name": "token", "type": "address", "internalType": "address"}]}]
```

### PearpadToken
```json
[{"type": "constructor", "inputs": [{"name": "name_", "type": "string", "internalType": "string"}, {"name": "symbol_", "type": "string", "internalType": "string"}, {"name": "metadata_", "type": "string", "internalType": "string"}, {"name": "creator_", "type": "address", "internalType": "address"}, {"name": "supply", "type": "uint256", "internalType": "uint256"}], "stateMutability": "nonpayable"}, {"type": "function", "name": "allowance", "inputs": [{"name": "owner", "type": "address", "internalType": "address"}, {"name": "spender", "type": "address", "internalType": "address"}], "outputs": [{"name": "", "type": "uint256", "internalType": "uint256"}], "stateMutability": "view"}, {"type": "function", "name": "approve", "inputs": [{"name": "spender", "type": "address", "internalType": "address"}, {"name": "value", "type": "uint256", "internalType": "uint256"}], "outputs": [{"name": "", "type": "bool", "internalType": "bool"}], "stateMutability": "nonpayable"}, {"type": "function", "name": "balanceOf", "inputs": [{"name": "account", "type": "address", "internalType": "address"}], "outputs": [{"name": "", "type": "uint256", "internalType": "uint256"}], "stateMutability": "view"}, {"type": "function", "name": "burn", "inputs": [{"name": "value", "type": "uint256", "internalType": "uint256"}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "burnFrom", "inputs": [{"name": "account", "type": "address", "internalType": "address"}, {"name": "value", "type": "uint256", "internalType": "uint256"}], "outputs": [], "stateMutability": "nonpayable"}, {"type": "function", "name": "creator", "inputs": [], "outputs": [{"name": "", "type": "address", "internalType": "address"}], "stateMutability": "view"}, {"type": "function", "name": "decimals", "inputs": [], "outputs": [{"name": "", "type": "uint8", "internalType": "uint8"}], "stateMutability": "view"}, {"type": "function", "name": "metadata", "inputs": [], "outputs": [{"name": "", "type": "string", "internalType": "string"}], "stateMutability": "view"}, {"type": "function", "name": "name", "inputs": [], "outputs": [{"name": "", "type": "string", "internalType": "string"}], "stateMutability": "view"}, {"type": "function", "name": "owner", "inputs": [], "outputs": [{"name": "", "type": "address", "internalType": "address"}], "stateMutability": "pure"}, {"type": "function", "name": "platform", "inputs": [], "outputs": [{"name": "", "type": "address", "internalType": "address"}], "stateMutability": "view"}, {"type": "function", "name": "symbol", "inputs": [], "outputs": [{"name": "", "type": "string", "internalType": "string"}], "stateMutability": "view"}, {"type": "function", "name": "tokenURI", "inputs": [], "outputs": [{"name": "", "type": "string", "internalType": "string"}], "stateMutability": "view"}, {"type": "function", "name": "totalSupply", "inputs": [], "outputs": [{"name": "", "type": "uint256", "internalType": "uint256"}], "stateMutability": "view"}, {"type": "function", "name": "transfer", "inputs": [{"name": "to", "type": "address", "internalType": "address"}, {"name": "value", "type": "uint256", "internalType": "uint256"}], "outputs": [{"name": "", "type": "bool", "internalType": "bool"}], "stateMutability": "nonpayable"}, {"type": "function", "name": "transferFrom", "inputs": [{"name": "from", "type": "address", "internalType": "address"}, {"name": "to", "type": "address", "internalType": "address"}, {"name": "value", "type": "uint256", "internalType": "uint256"}], "outputs": [{"name": "", "type": "bool", "internalType": "bool"}], "stateMutability": "nonpayable"}, {"type": "event", "name": "Approval", "inputs": [{"name": "owner", "type": "address", "indexed": true, "internalType": "address"}, {"name": "spender", "type": "address", "indexed": true, "internalType": "address"}, {"name": "value", "type": "uint256", "indexed": false, "internalType": "uint256"}], "anonymous": false}, {"type": "event", "name": "OwnershipTransferred", "inputs": [{"name": "previousOwner", "type": "address", "indexed": true, "internalType": "address"}, {"name": "newOwner", "type": "address", "indexed": true, "internalType": "address"}], "anonymous": false}, {"type": "event", "name": "Transfer", "inputs": [{"name": "from", "type": "address", "indexed": true, "internalType": "address"}, {"name": "to", "type": "address", "indexed": true, "internalType": "address"}, {"name": "value", "type": "uint256", "indexed": false, "internalType": "uint256"}], "anonymous": false}, {"type": "error", "name": "ERC20InsufficientAllowance", "inputs": [{"name": "spender", "type": "address", "internalType": "address"}, {"name": "allowance", "type": "uint256", "internalType": "uint256"}, {"name": "needed", "type": "uint256", "internalType": "uint256"}]}, {"type": "error", "name": "ERC20InsufficientBalance", "inputs": [{"name": "sender", "type": "address", "internalType": "address"}, {"name": "balance", "type": "uint256", "internalType": "uint256"}, {"name": "needed", "type": "uint256", "internalType": "uint256"}]}, {"type": "error", "name": "ERC20InvalidApprover", "inputs": [{"name": "approver", "type": "address", "internalType": "address"}]}, {"type": "error", "name": "ERC20InvalidReceiver", "inputs": [{"name": "receiver", "type": "address", "internalType": "address"}]}, {"type": "error", "name": "ERC20InvalidSender", "inputs": [{"name": "sender", "type": "address", "internalType": "address"}]}, {"type": "error", "name": "ERC20InvalidSpender", "inputs": [{"name": "spender", "type": "address", "internalType": "address"}]}]
```

## Public REST API

Base URL: `https://pearpad.fun/api`, free to use, no key. Rate limit: 10 req/s per IP (burst 30); heavy usage gets HTTP 429. Data comes from the pearpad indexer and tracks the chain within a block or two. Most responses carry an `asOf` object of `{block, status}` telling you which block the data reflects; `/profiles` and `/meta` are the exceptions and omit it. Errors return `{"detail": "..."}`.

| Endpoint | Returns |
|---|---|
| `GET /tokens` | tokens active in the last 24h, newest first, capped at 500 |
| `GET /tokens/<address>` | one token's detail, same row shape as the list |
| `GET /tokens/<address>/trades?limit=100` | trade history (side, src, amounts, reserves, tx hash, block, time; max 500) |
| `GET /tokens/<address>/bars?step=60&from=&to=` | true OHLC bars as `{t,o,h,l,c,v}` |
| `GET /tokens/<address>/candles?step=60&since=` | lighter high/low buckets as `{bucket,lo,hi,vol,n}` |
| `GET /tokens/<address>/holders?limit=50` | holder addresses and balances (max 200) |
| `GET /tokens/<address>/meta` | the token's logo plus its IPFS metadata |
| `GET /profiles` | address-keyed map of usernames and avatars |
| `GET /live` | Server-Sent Events. Each event names the tokens that moved and embeds their rows plus recent trades, so listen here instead of polling |

`step` is one of `60, 300, 900, 3600, 14400, 86400` seconds. `from`, `to` and `since` are unix seconds. An unrecognised parameter name is ignored rather than rejected, so a typo silently returns the default bucket size.

Amounts and balances are decimal strings in base units, since they overflow a JSON number. Prices are floats.

Example:

```bash
curl https://pearpad.fun/api/tokens
curl "https://pearpad.fun/api/tokens/0xeb4ba862119ba6db283c411f060df0a3d53f2f0f/trades?limit=20"
```

# Argon

Hourly inference that decides when Uniswap LP should be **in the pool** and when it should sit in **cash**.

Argon is a dual-chain LP vault for [Arbitrum Open House Singapore: Online Buildathon](https://www.hackquest.io/hackathons/Arbitrum-Open-House-Singapore-Online-Buildathon). A user deposits liquidity once. Every hour an agent publishes a 1-hour price forecast, then mints or burns Uniswap positions on the user’s behalf. The user never clicks in and out of ranges.

**Chains:** Arbitrum One (`42161`) and Robinhood Chain (`4663`).  
**DEX:** Uniswap v3 and v4.  
**Volatile legs the agent forecasts:** `ETH/USD` and `LINK/USD` (LINK/ETH is derived).

Module graph, hourly loop, and decision policy are in the [Argon architecture canvas](/Users/wang/.cursor/projects/Users-wang-Untitled/canvases/argon-architecture.canvas.tsx) — open it beside the chat.

---

## Problem

Concentrated Uniswap LP earns fees only while the price stays in range. A one-hour dump (ETH toward $2,300, or LINK selling off independently) pushes the position out of range, realizes impermanent loss, and leaves the LP holding the asset that just fell.

Manual LPs cannot sit on the books every hour. Existing automators rebalance ranges; they do not **leave the pool** when the next hour looks red and **re-enter** when it looks green.

## Solution

1. User deposits into a per-chain vault (not directly into Uniswap).
2. Off-chain agent infers 1H-ahead prices for ETH and LINK and commits that inference.
3. A policy engine maps forecasts onto one action per pool: `ENTER`, `HOLD`, or `EXIT`.
4. A keeper executes mint / increase / decrease / collect / burn through the vault.
5. Idle liquidity stays in the vault as the underlying tokens, ready for the next green hour.

Worked example: agent predicts ETH → $2,300 in one hour. Argon exits `WETH/USDC` and `WETH/USDG`. Next hour, if the ETH forecast is green, it opens those LP positions again with the same deposited liquidity. If LINK is still green while ETH is red, `LINK/USDC` can stay in the pool — the product is not ETH-only.

---

## Four pools

| # | Pair | Chain | DEX | Why it is in the set |
|---|------|-------|-----|----------------------|
| 1 | WETH / USDC | Arbitrum One | Uniswap v3 | ETH vs native Circle USDC. Deep, the core ETH-stable book. |
| 2 | LINK / WETH | Arbitrum One | Uniswap v3 | LINK as a first-class volatile leg, not an ETH side-effect. |
| 3 | LINK / USDC | Arbitrum One | Uniswap v4 | LINK vs stable so LINK can stay in when ETH is the asset that looks red. |
| 4 | WETH / USDG | Robinhood Chain | Uniswap v3 | Robinhood prize-lane pool. USDG is the chain’s native stable (USDC in becomes USDG). |

**Out of scope for v1:** Base `fETH/USDC`, Ethereum-mainnet `ETH/USDT`, and Arbitrum `WETH/USDT0` (redundant with pool 1). Robinhood `LINK/WETH` is a v2 add-on once pool depth is confirmed.

### Canonical tokens

**Arbitrum One**

| Token | Address |
|-------|---------|
| WETH | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` |
| USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| LINK | `0xf97f4df75117a78c1A5a0DBb814Af92458539FB4` |

**Robinhood Chain**

| Token | Address |
|-------|---------|
| WETH | `0x0bd7d308f8e1639fab988df18a8011f41eacad73` |
| USDG | `0x5fc5360d0400a0fd4f2af552add042d716f1d168` |
| LINK | `0x492641f648a4986844848e0befe66d14817bce34` (held for v2; not in the four pools) |

Fee tiers are resolved at implementation against the deepest honest Uniswap book (prefer v3 0.05% / 0.3% where TVL is real; do not chase a thin v4 APR screenshot).

---

## Architecture

Argon splits into **custody (on-chain)** and **judgment (off-chain)**. The agent never holds user keys. Vaults never call a model. The keeper is the only bridge between the two.

```
User wallet ──► dApp ──► Vault (Arb) ──► Uniswap v3 / v4
                    └──► Vault (RH)  ──► Uniswap v3

Market data ─┐
Chainlink ───┴► Inference agent ──► Policy engine ──► Keeper
                                                      │
                                                      ├─► Vault (Arb)
                                                      └─► Vault (RH)
```

### Modules

| Module | Lives | Job |
|--------|-------|-----|
| **dApp** | Off-chain | Connect wallet, deposit / withdraw, show the latest 1H forecast, per-pool status (`in range` / `idle in vault`), and the last keeper tx. |
| **Vault (Arbitrum)** | Solidity, chain 42161 | Escrow WETH, USDC, LINK. Only the keeper role may mint or burn Uniswap positions. Users can always emergency-withdraw idle balances. |
| **Vault (Robinhood)** | Solidity, chain 4663 | Same pattern for WETH and USDG. Separate contract so a Robinhood outage cannot freeze Arbitrum funds. |
| **Uniswap adapters** | On-chain | v3 `NonfungiblePositionManager` for pools 1, 2, 4. v4 `PoolManager` / position manager for pool 3. |
| **Feature pipeline** | Off-chain | Hourly OHLCV, realized vol, pool tick / inventory, Chainlink spot. Builds the model input vector. |
| **Inference agent** | Off-chain | Every hour, emit `{ ethUsd1h, linkUsd1h, linkEth1h, submittedAt }`. Commit a hash on-chain so judges can audit that the same number drove the tx. |
| **Policy engine** | Off-chain | Map forecasts onto `ENTER` / `HOLD` / `EXIT` per pool. Apply deadbands, gas vs expected IL, sequencer-uptime, and cooldown. |
| **Keeper** | Off-chain signer | Submit the txs. Never a `ONLYOWNER` rug path: it can only call vault `rebalance()` with slippage and range bounds already set in the contract. |
| **Inference registry** | On-chain | `submit(bytes32 forecastHash, uint64 hourId)` so the hourly call is public even if the model weights stay off-chain. |
| **Oracles** | Chainlink | ETH/USD and LINK/USD on both chains, plus the L2 sequencer uptime feed. Vaults refuse to rebalance if the sequencer is down or the feed is stale. |

### Why two vaults, not a bridge

v1 does **not** move capital between Arbitrum and Robinhood in the critical path. The user deposits on each chain they want exposure to. The same agent and the same UI drive both vaults. Bridging USDC → USDG via Across is a later stretch, not required to demo the hourly loop.

---

## Hourly loop

Cadence is one inference per hour, on the hour (UTC).

| Minute | Step | Module |
|--------|------|--------|
| `:00` | Pull candles, Chainlink spot, current ticks, vault balances | Feature pipeline |
| `:01` | Infer 1H-ahead ETH and LINK; derive LINK/ETH | Inference agent |
| `:01` | `submit(forecastHash, hourId)` on both chains | Inference registry |
| `:02` | Score each of the four pools → `ENTER` / `HOLD` / `EXIT` | Policy engine |
| `:03–:08` | Keeper sends `rebalance(poolId, action, range, minOut)` | Vaults → Uniswap |
| rest of hour | Positions sit. dApp polls status. No further txs unless emergency | — |

On `EXIT`: decrease liquidity, collect fees and tokens into the vault, leave them idle (do not force-swap into a single asset unless the policy asks for it).  
On `ENTER`: mint a concentrated range around the current tick using vault balances.  
On `HOLD`: collect fees only if gas-positive; do not touch the range.

---

## Decision policy

The agent forecasts **tickers**, not pools. Policy then fans those tickers onto the four books.

| 1H forecast | WETH/USDC | LINK/WETH | LINK/USDC | WETH/USDG |
|-------------|-----------|-----------|-----------|-----------|
| ETH red, LINK green | EXIT | EXIT if ratio breaks | HOLD / ENTER | EXIT |
| LINK red, ETH green | HOLD | EXIT | EXIT | HOLD |
| Both red | EXIT | EXIT | EXIT | EXIT |
| Both green | ENTER | ENTER | ENTER | ENTER |
| Move inside deadband | HOLD | HOLD | HOLD | HOLD |

**ETH → $2,300 example:** pools 1 and 4 exit. Pool 3 (`LINK/USDC`) stays if LINK is green. Pool 2 (`LINK/WETH`) exits if the ETH leg would dominate IL. Next hour, if ETH prints green, pools 1 and 4 re-enter with the user’s original deposit.

Deadband: do not exit for a predicted move smaller than the current range width plus estimated gas. Cooldown: at most one `EXIT→ENTER` round-trip per pool per two hours unless the forecast flips hard.

---

## Trust and safety

- Users retain withdraw rights on idle vault balances at all times.
- Keeper cannot send tokens to an arbitrary address; adapters can only talk to Uniswap position managers and the vault.
- Slippage, tick width, and max gas are contract parameters, not keeper discretion.
- Pause + timelock on adapter upgrades.
- Sequencer-uptime and stale-oracle guards on both L2s.
- Forecast hash is on-chain; model weights can stay private without hiding the number that triggered the trade.

---

## Tech stack

| Layer | Choice |
|-------|--------|
| Contracts | Solidity 0.8.x, Foundry. Stylus later if we need a cheaper tick-math helper. |
| Uniswap | v3 NPM on Arb + Robinhood; v4 on Arb for `LINK/USDC`. |
| Oracles | Chainlink Data Feeds + L2 sequencer feed. |
| Agent | Python (features + model) or TypeScript if we keep the first model as gradient boosting on 1H candles. |
| Keeper | viem / ethers with a dedicated hot wallet per chain, funded in ETH for gas. |
| dApp | Next.js, wagmi, permissionless wallet connect for 42161 and 4663. |
| RPCs | `https://arb1.arbitrum.io/rpc` and `https://rpc.mainnet.chain.robinhood.com`. |

---

## Planned repo layout

```
contracts/          Foundry project, shared interfaces
  src/arbitrum/     Vault + v3/v4 adapters + inference registry
  src/robinhood/    Vault + v3 adapter + inference registry
  test/
agent/              Feature pipeline, model, policy, keeper
apps/web/           Deposit, forecasts, position status
```

---

## Demo script (target)

1. Deposit USDC + WETH on Arbitrum; deposit WETH + USDG on Robinhood.
2. Agent submits a green 1H forecast → four (or the funded) pools show `IN_POOL`.
3. Inject a bearish ETH inference (ETH → $2,300) → pools 1 and 4 go `IDLE`; LINK/USDC can stay.
4. Next hour, green ETH → those vault balances mint LP again.
5. Show the on-chain `forecastHash` matching the UI number.

---

## Status

Write-up and architecture locked to the four pools above. Implementation has not started.

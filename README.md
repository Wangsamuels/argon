# Argon

Hourly inference that decides when Uniswap LP should be **in the pool** and when it should sit in **cash**.

Argon is a dual-chain LP vault for [Arbitrum Open House Singapore: Online Buildathon](https://www.hackquest.io/hackathons/Arbitrum-Open-House-Singapore-Online-Buildathon). A user deposits on one chain. Every hour a hosted model publishes an 8-hour-ahead ETH **price**. The percent the gate sees is the move still left from the current price to that stored target, not a spot stop. The user does not click in and out of ranges.

**Chains:** Arbitrum One (`42161`) and Robinhood Chain (`4663`). Same contract addresses, separate state, no bridge.  
**DEX:** Uniswap v3. Live pools are WETH/USDC on Arbitrum and WETH/USDG on Robinhood.  
**Forecast:** one 8h ETH price per hour. 1h and 2h are the remaining slices of older 8h prices. LINK later.

Module graph, hourly loop, and decision policy are in the [Argon architecture canvas](/Users/wang/.cursor/projects/Users-wang-Untitled/canvases/argon-architecture.canvas.tsx) — open it beside the chat.

Web-dev spec (site × agent × Arbitrum): [docs/web-architecture.md](docs/web-architecture.md).  
Heroku deploy + where the 8h/9-tick window is stored: [docs/heroku-deploy.md](docs/heroku-deploy.md).  
Smart contracts (what we deploy on Arb + Robinhood): [docs/contracts.md](docs/contracts.md).

---

## Problem

Concentrated Uniswap LP earns fees only while the price stays in range. A one-hour dump (ETH toward $2,300, or LINK selling off independently) pushes the position out of range, realizes impermanent loss, and leaves the LP holding the asset that just fell.

Manual LPs cannot sit on the books every hour. Existing automators rebalance ranges; they do not **leave the pool** when the next hour looks red and **re-enter** when it looks green.

## Solution

1. User picks Arbitrum or Robinhood and deposits into that chain's vault (not directly into Uniswap).
2. Each hour the 8h LightGBM pickle emits one ETH price eight hours ahead, anchored to the last closed hourly candle.
3. Older 8h prices stay fixed. Every new hour, the percent is recalculated from the **current** price to each price that is still open.
4. Policy: **ENTER** only if the fresh 8h remainder and the 1h/2h averages are inside the band; **EXIT** if the 1h or 2h remainder is outside.
5. A keeper executes mint / increase / decrease / collect / burn through the vault.
6. Idle liquidity stays in the vault until the next in-gate hour.

Worked example: stored target `$2,754` from a `$2,700` close was `+2.0%` at birth. One hour later price is `$2,710`, so the remaining move is `2754 / 2710 − 1 = +1.62%`. Seven hours later price is `$2,748`, so the 1h gate sees `+0.22%`, not the original `+2.0%`. First on-chain LP decision is after 9 registry submits (warmup).

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
| **dApp** | Vercel | Connect wallet, pick one chain, deposit / withdraw, show the 8h price and the updated 1h / 2h / 8h percents, pool APR and TVL, and the signer's gate. |
| **Vault (Arbitrum)** | Solidity, chain 42161 | Escrow WETH and USDC. Keeper mints the Uniswap v3 WETH/USDC position (pool 1). |
| **Vault (Robinhood)** | Solidity, chain 4663 | Same bytecode for WETH and USDG. Keeper mints WETH/USDG (pool 4). A Robinhood outage does not freeze Arbitrum funds. |
| **Uniswap adapters** | On-chain | v3 `NonfungiblePositionManager`. Live use is pools 1 and 4. Pools 2 and 3 (LINK) are later. |
| **Feature pipeline** | Off-chain | Hourly OHLCV, realized vol, pool tick / inventory, Chainlink spot. Builds the model input vector. |
| **Hosted model** | Heroku | Load the 8h pickle. Each hour store `predEthUsd8h`. 1h and 2h are averages of still-open targets. Commit a hash on-chain when dry-run is off. |
| **Policy engine** | Off-chain | Dual-horizon gate below. Per-wallet Safe / Balanced / Aggressive / Custom bands. Sequencer-uptime and cooldown. |
| **Keeper** | Off-chain signer | Same forecast to both chains. Pool 1 on Arbitrum, pool 4 on Robinhood. Can only call vault `rebalance()`. |
| **Inference registry** | On-chain | `submit(bytes32 forecastHash, uint64 hourId)` so the hourly call is public even if the model weights stay off-chain. |
| **Oracles** | Chainlink | ETH/USD and LINK/USD on both chains, plus the L2 sequencer uptime feed. Vaults refuse to rebalance if the sequencer is down or the feed is stale. |

### Why two vaults, not a bridge

v1 does **not** move capital between Arbitrum and Robinhood in the critical path. The user deposits on each chain they want exposure to. The same agent and the same UI drive both vaults. Bridging USDC → USDG via Across is a later stretch, not required to demo the hourly loop.

---

## Hourly loop

Cadence is one inference per hour, on the hour (UTC).

| Minute | Step | Module |
|--------|------|--------|
| `:00` | Pull Coinbase hourly ETH-USD through the last closed hour | Feature pipeline |
| `:01` | 8h pickle → `predEthUsd8h`. Average still-open targets into 1h and 2h percents | Hosted model (Heroku) |
| `:01` | `submit(hourId, pct1h, pct2h, pct8h, forecastHash)` on both chains | Inference registry |
| `:02` | Vault gate, then each stored signer gate → EXIT / ENTER / HOLD | Policy engine |
| `:03–:08` | Keeper sends `rebalance(poolId, action, range, minOut)` | Vaults → Uniswap |
| rest of hour | Positions sit. dApp polls status. No further txs unless emergency | — |

On `EXIT`: decrease liquidity, collect fees and tokens into the vault, leave them idle (do not force-swap into a single asset unless the policy asks for it).  
On `ENTER`: mint a concentrated range around the current tick using vault balances.  
On `HOLD`: collect fees only if gas-positive; do not touch the range.

---

## Decision policy

The model publishes a **price**. The gate reads the **percent still left** to reach that price from the current hourly close.

| Horizon | What it is | Vault default |
|---------|------------|---------------|
| 8h | `(this hour's predicted price / current close) − 1` | `gate8hBps = 200` → **±2.0%**, ENTER only |
| 2h | Average 2h slice of every stored 8h price that still has at least 2 hours left | `gate2hBps = 250` → **±2.5%** |
| 1h | Average 1h slice of every stored 8h price that still covers the next hour | `gate1hBps = 100` → **±1.0%** |

A slice of a target with `R` hours left, over the next `H` hours, is `(target / current) ^ (H / R) − 1`. The new 8h price is included in that average immediately. A target with fewer than `H` hours left is left out.

```
EXIT  if  |1h| ≥ 1.0%  OR  |2h| ≥ 2.5%
ENTER if  idle AND |1h| < 1.0% AND |2h| < 2.5% AND |8h| < 2.0%
HOLD  if  already in AND not EXIT
```

Do not exit only when both short horizons are large. Do not open unless all three are inside.

There is no separate 1h or 2h model. Do not divide the 8h percent by 8.

### Signer gates

The shared vault still has one on-chain gate and one Uniswap position. Each wallet can also store its own band. The keeper writes that wallet's `enter` / `hold` / `exit` on the wallet's own row. It does not open a second LP position.

| Preset | 1h | 2h | 8h |
|--------|----|----|-----|
| Safe | ±0.6% | ±1.2% | ±1.0% |
| Balanced | ±1.0% | ±2.5% | ±2.0% |
| Aggressive | ±2.0% | ±4.0% | ±3.5% |

Custom sets the 1h top (+) and bottom (−). Those can differ. The 2h and 8h bands stay Balanced. The wallet signs `argon-gate:{address}:{preset}:{topBps}:{bottomBps}:{issuedAt}`. One row per checksum address. A stale signature is rejected.

Hours 0–8 of registry submits are warmup: store forecasts, no enter/exit. Cooldown: no `EXIT → ENTER` on a pool inside two hours unless EXIT fires again. LINK pools 2 and 3 stay off this ETH gate.

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
| Model | 8h LightGBM pickle on Heroku. Hourly Coinbase ETH-USD bars. |
| Keeper | viem / ethers with a dedicated hot wallet per chain, funded in ETH for gas. |
| dApp | Next.js, wagmi, permissionless wallet connect for 42161 and 4663. |
| RPCs | `https://arb1.arbitrum.io/rpc` and `https://rpc.mainnet.chain.robinhood.com`. |

---

## Planned repo layout

```
contracts/          Foundry project (live on Arb + RH)
agent/              Heroku: pickle infer, Postgres, dual-horizon keeper
apps/web/lib/       Vercel REST + wagmi ABIs (pages still to scaffold)
```

---

## Hackathon fit

| Criterion | How Argon hits it |
|-----------|-------------------|
| Smart contract quality | Thin vaults, no custodian key, Uniswap adapters isolated, oracle + sequencer guards, Foundry tests on mint/burn/emergency withdraw. |
| Product-market fit | LPs already chase these four books; they lack an hourly “get out before the dump” switch. |
| Innovation | Inference-gated LP, not another range rebalancer. LINK is a second market so the agent is not an ETH bot with extra steps. |
| Real problem | Impermanent loss on concentrated ETH and LINK ranges is the actual PnL leak. |
| Prize lanes | Arbitrum One for pools 1–3; Robinhood Chain for pool 4. One product, both reserved tracks. |

---

## Demo script (target)

1. Deposit USDC + WETH on Arbitrum; deposit WETH + USDG on Robinhood.
2. After warmup, an in-gate remainder (1h < 1% and 2h < 2.5% and 8h < 2%) → funded ETH-stable pools show `IN_POOL`.
3. Next hour the 2h remainder is −2.8% → pools 1 and 4 go `IDLE` even if the 1h remainder is small.
4. A later hour all three back inside → those vault balances mint LP again.
5. Show the on-chain `forecastHash` matching the UI number.

---

## Status

Contracts are live on Arbitrum One (`42161`) and Robinhood Chain (`4663`). The addresses in [contracts/deployments.md](contracts/deployments.md) are the **previous** bytecode. The share-price, NAV, withdraw, and oracle fixes in `contracts/src` take effect only after a new deploy. Both vaults were empty when that was reviewed, so the redeploy does not move user funds.

On that redeploy:

- Arbitrum deposit fee `setDepositFeeBps(10)`. Robinhood `setDepositFeeBps(60)`. These cover the Chainlink update threshold. The fee defaults to 0 until the owner sets it.
- Robinhood `ChainlinkEthOracle` `maxDelay` is 90_000 seconds (25h). The oracle already on Robinhood still uses 1 hour and will reject deposits after the feed goes quiet.
- Both deploy scripts set the chain's canonical Uniswap `SwapRouter02`, so a WETH-only or stable-only deposit can be balanced before entering the pool. The vault grants only an exact, per-swap allowance and clears it immediately after the swap.
- The keeper key is read only by the clock dyno. The web process ignores `KEEPER_PRIVATE_KEY`. Do not put that key in Vercel, logs, or the model pickle. A multisig owner is not in this build.

Withdraw still pays the user's pro-rata WETH and stable together. That matches the shared-vault design. Per-signer gates stay off-chain (`POST /gates`); the vault's one Uniswap position still follows the on-chain Balanced bands.

Agent (Heroku infer + Postgres + keeper): [`agent/`](agent/README.md).  
Frontend glue for Vercel: [`apps/web/lib/`](apps/web/lib/agent.ts).

The Vercel app reads Heroku. Pool cards use `GET /pools` (`aprPct`, `poolTvlUsd`, `ethUsd`). The hero uses `predEthUsd8h` plus the updated percents. Signer gates use `POST /gates`. See [`agent/README.md`](agent/README.md).

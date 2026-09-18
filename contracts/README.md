# Argon contracts

Same Solidity on **Arbitrum One (42161)** and **Robinhood Chain (4663)**. Constructor args change: tokens, Uniswap NPM, ETH/USD feed, gated `poolId`.

Users call `deposit` / `withdraw`. The Heroku keeper calls `InferenceRegistry.submit` then `ArgonVault.rebalance`. The vault re-checks the dual-horizon gate on-chain.

```
User  ──deposit/withdraw──►  ArgonVault  ──mint/burn LP──►  Uniswap v3 NPM
                                ▲
                                │ rebalance(ENTER|EXIT|HOLD)
Heroku ──submit(1h,2h,8h,hash)──► InferenceRegistry
```

## Layout


| Path                 | Chain   | Role                                                                                                                 |
| -------------------- | ------- | -------------------------------------------------------------------------------------------------------------------- |
| `InferenceRegistry`  | both    | One forecast per `hourId`. Hash = `keccak256(abi.encode(hourId, pct1h, pct2h, pct8h, modelId))`. Warmup = 9 submits. |
| `ArgonVault`         | both    | Shares (USD-8), flatten-then-pro-rata withdraw, keeper `rebalance`.                                                  |
| `UniswapV3Adapter`   | both    | NPM mint / increase / exit. Only the vault may call it.                                                              |
| `ChainlinkEthOracle` | both    | ETH/USD 8dp + optional sequencer feed. Robinhood may pass sequencer `address(0)`.                                    |
| `DualHorizonGate`    | library | EXIT if `|1h|≥100` or `|2h|≥250`. ENTER if idle and all three inside (`8h < 200`).                                   |


Gated pools in v1: **pool 1** (Arb WETH/USDC 500) and **pool 4** (RH WETH/USDG 500). Pool 2 (LINK) is configured `gated=false` and `rebalance` reverts.

## Build / test

Foundry `solc 0.8.24` lives at `~/.foundry/bin` (add that to `PATH` if `forge` is not found). From the **repo root** (this folder is `contracts/`):

```bash
cd ~/Untitled
forge test -vv
```

## Deploy

Same terminal is fine. You do **not** type RPC URLs — they are already in Foundry (`arbitrum` / `robinhood`). Skip `--verify` unless you have an Arbiscan API key.

Create the env file once, then fill `PRIVATE_KEY` (deployer, needs ETH on **both** chains) and `KEEPER` (Heroku hot wallet; can be the same EOA):

```bash
cd ~/Untitled
cp contracts/.env.example contracts/.env
```

Then deploy:

```bash
cd ~/Untitled
set -a && source contracts/.env && set +a

forge script contracts/script/DeployArbitrum.s.sol:DeployArbitrum \
  --rpc-url arbitrum --broadcast --chain 42161

forge script contracts/script/DeployRobinhood.s.sol:DeployRobinhood \
  --rpc-url robinhood --broadcast --chain 4663
```

Arbitrum wires WETH/USDC, NPM, Chainlink ETH/USD + sequencer, `poolId = 1`.  
Robinhood wires WETH/USDG, NPM, Chainlink ETH/USD `0x78F3…d3A9`, `poolId = 4`. Sequencer check is skipped until a RH sequencer feed is published.

Two deployments, not one bridged vault. Fund the keeper with gas on **both** chains.

## Keeper loop (after warmup)

1. `hash = registry.computeHash(hourId, pct1hBps, pct2hBps, pct8hBps)`
2. `registry.submit(hourId, pct1hBps, pct2hBps, pct8hBps, hash)` — once per hour, monotonic
3. `vault.rebalance(hourId, poolId, action, tickLower, tickUpper, amountAMin, amountBMin)`

`action` must match the on-chain gate (keeper may pass `HOLD` instead of `ENTER`). No `EXIT → ENTER` within 2 hours. `HOLD` still allowed during hours 0–7; first `ENTER`/`EXIT` at hour 8 (`forecastCount >= 9`).

## User API

- `deposit(token, amount)` / `depositETH()` — WETH or the chain stable; mints shares from ETH/USD
- `withdraw(shares)` — exits LP if needed, then pays pro-rata WETH + stable
- `emergencyWithdraw()` — full share burn; works while keeper is paused


# Argon agent

Hourly ETH forecast service. This is the **only** process that loads `eth_8h_lgbm.pkl`, fetches Coinbase hourly candles, writes Postgres, and signs keeper txs. The Vercel site reads this API and asks the wallet to sign a gate. User wallets never call `submit` or `rebalance`.

Live contracts (addresses differ per chain: Arbitrum `42161`, Robinhood `4663`):

| Contract | Address |
|----------|---------|
| InferenceRegistry | Arb `0x8F288a7a6E28a5d44980De19502522C376965afe` · RH `0x256A61b459BFdb48B4C04DE5Ba13E0dFBC326508` |
| ArgonVault | Arb `0xe0eb546A1F8dcEc7B124cF8fE253de34d54A6c61` · RH `0x89403CA4AdB3A89A0173B7494903B4247881966f` |
| UniswapV3Adapter | Arb `0x05734481536644bc20e671Db28f5b4c05B7D64D4` · RH `0xEDa50F3F5530E9BFFD427c1DB0E0a8f3D05cCC9D` |

Keeper / owner on both chains: `0x9642b6D1Db5D1A3B0A61a831099568bbCbC04D4E`.

```
Coinbase hourly ETH-USD ──► infer.py (8h LightGBM pickle)
                                  │
                                  ▼
                         predEthUsd8h from last closed close
                                  │
                                  ▼
              remaining % from current price to every open target
              1h = average slice of targets covering the next hour
              2h = average slice of targets with ≥2h left
              8h = this hour's target vs current close
                                  │
          ┌───────────────────────┴────────────────────────┐
          ▼                                                ▼
   Postgres ──GET──► Vercel                          keeper EOA
   forecasts, pools, signer_gates                    submit + rebalance
                                                     pool 1 Arb, pool 4 RH
```

## What you must add

These are **not** in git:

1. **`models/eth_8h_lgbm.pkl`** — the Colab pickle you already downloaded. Copy it here, or set `MODEL_8H_URL` to a public/signed HTTPS file the dyno can download at boot.
2. **`KEEPER_PRIVATE_KEY`** — the EOA already set as `keeper` on the registry and vault. Fund it with ETH on **both** Arbitrum and Robinhood for gas.
3. **`FRONTEND_ORIGIN`** — your Vercel production URL (preview `*.vercel.app` is already allowed).

The only model head is `eth_8h_lgbm.pkl`. 1h and 2h are not separate pickles and are not `pred_8h / 8`.

## Local run

```bash
cd agent
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# edit .env: copy pickle to models/eth_8h_lgbm.pkl
# leave DRY_RUN=true until you want on-chain txs

PYTHONPATH=. python infer_once.py          # one tick → sqlite forecasts.db
PYTHONPATH=. uvicorn app:app --reload --port 8000
# GET http://127.0.0.1:8000/forecasts/latest
PYTHONPATH=. pytest
```

With `DRY_RUN=true` the API and DB still update; `submit` / `rebalance` are skipped.

## Hourly loop (what the clock does)

Every UTC hour (`clock.py`):

1. Fetch ~60 days of hourly ETH-USD from Coinbase (no API key); drop the in-progress hour. The last bar **must** be `hourId-1`. A previous-day bar fails the tick instead of being stamped on the current hour.
2. Rebuild the training feature set; run the 8h pickle → predicted ETH **price** in 8h (`predEthUsd8h`) from the last closed hour’s close. Dashboard still shows the derived %.
3. Restate every stored 8h price that is still open as the percent remaining from the current close. `ethPct1h` is the average 1h slice of those targets. `ethPct2h` is the average 2h slice of targets with at least two hours left. `ethPct8h` is only this hour's new target versus the current close.
4. Convert to signed bps (`-1.50%` → `-150`).
5. `forecastHash = keccak256(abi.encode(hourId, pct1h, pct2h, pct8h, keccak256("eth-1-2-8h-v1")))`.
6. Insert Postgres. Mark matured rows when `now_hour >= hour_id + 8`.
7. Gate (identical to Solidity):
   - hours 0–7 (fewer than 9 rows): `warmup` — **submit only**, no enter/exit.
   - `EXIT` if `|1h| ≥ 1%` **or** `|2h| ≥ 2.5%`.
   - `ENTER` if idle and all three inside (`|8h| < 2%` as well).
   - `HOLD` if already in pool and not EXIT.
8. For each stored signer, write that wallet's `enter` / `hold` / `exit` on its own `signer_gates` row. The shared vault still rebalances once, with the on-chain Balanced bands.
9. Keeper `registry.submit(...)` then `vault.rebalance(hourId, poolId, action, ticks, 0, 0)` when `DRY_RUN` is off:
   - Arbitrum `poolId = 1` (WETH/USDC 500)
   - Robinhood `poolId = 4` (WETH/USDG 500)
10. The vault **re-checks** the gate on-chain. If the keeper passes ENTER when the stored bps say EXIT, the tx reverts.

The website does not call `submit` or `rebalance`. It reads forecasts and pools, and posts a signed gate.

## REST the frontend calls

Base URL: `https://<app>.herokuapp.com` → `NEXT_PUBLIC_AGENT_URL`.

| Method | Path | Use |
|--------|------|-----|
| `GET` | `/health` | Agent up, pickle present |
| `GET` | `/status` | Warmup, last hour, gates |
| `GET` | `/forecasts/latest` | Dashboard hero |
| `GET` | `/forecasts?limit=24` | History |
| `GET` | `/forecasts/:hourId` | Predicted vs realized |
| `GET` | `/pools` | Arb and Robinhood TVL, ETH, APR |
| `GET` | `/gates/:address` | That signer's stored gate |
| `POST` | `/gates` | Save a signed gate |

There is **no** public `POST /predict`. CORS allows `GET` and `POST` from `FRONTEND_ORIGIN` plus `https://*.vercel.app`.

Pool cards bind `aprPct`, `poolTvlUsd`, and `ethUsd`. Robinhood APR is the fixed Uniswap WETH/USDG figure `35.51`. Poll `/pools` about every 15 seconds. A missing `txHash` does not mean the forecast is missing; `DRY_RUN` leaves it null.

`/vault` and `/portfolio/:address` read Arbitrum and Robinhood concurrently. Chain-wide vault state is cached for 12 seconds so simultaneous dashboard polls share the same RPC work; override this with `PORTFOLIO_CACHE_SECONDS` and bound an individual RPC request with `PORTFOLIO_RPC_TIMEOUT_SECONDS`.

Warmup on the dashboard uses `hoursUntilFirstDecision` from `/status` (stored inferences). `onchainForecastCount` stays 0 until live submits.

Signer gate message, signed with `personal_sign`:

`argon-gate:{addressLowercase}:{preset}:{topBps}:{bottomBps}:{issuedAtUnix}`

Safe is `60/-60`, Balanced `100/-100`, Aggressive `200/-200`. Custom sends its own 1h top and bottom. `issuedAt` must be within two hours and newer than the row already stored.

`GET /forecasts/latest` shape:

```json
{
  "hourId": 488888,
  "targetHourId": 488896,
  "submittedAt": "2026-09-29T11:00:00+00:00",
  "predEthUsd8h": 2374.0,
  "barCloseUsd": 2410.12,
  "expectedEthUsd1h": null,
  "ethPct1h": -0.40,
  "ethPct2h": -1.10,
  "ethPct8h": -1.50,
  "ethPct8hSource": "lgbm",
  "spotUsd": 2410.12,
  "modelId": "eth-1-2-8h-v1",
  "status": "pending",
  "action": "enter",
  "gate1hBps": 100,
  "gate2hBps": 250,
  "gate8hBps": 200,
  "warmupComplete": true,
  "forecastHash": "0x…",
  "txHash": "0x…",
  "barTime": "2026-09-29T10:00:00+00:00",
  "barHourId": 488887,
  "live": true,
  "trippedHorizons": []
}
```

The dashboard must show `forecastHash` next to `InferenceRegistry.getForecast(hourId)`. They have to match.

Frontend glue already lives in this monorepo:

- `apps/web/lib/agent.ts` — fetch helpers
- `apps/web/lib/policy.ts` — same gate (display only)
- `apps/web/lib/chains.ts` — Arb + Robinhood + live addresses
- `apps/web/lib/abis.ts` — deposit / withdraw / registry reads
- `apps/web/.env.example` — Vercel env vars

Scaffold Next.js + wagmi against those files. Users only sign `approve` + `deposit` / `withdraw`. Hide `rebalance`.

## Host on Heroku

The GitHub repo is a monorepo. Root `Procfile` / `requirements.txt` point at `agent/`, so **Deploy → GitHub → Deploy Branch** works. Do not use Heroku Git `git push heroku` unless you also push those root files.

### Dashboard (GitHub already connected)

1. **Deploy branch** — yellow banner: switch the deploy branch from `master` to `main`, then **Manual deploy → main → Deploy Branch**.
2. **Buildpacks** (Settings → Buildpacks), in this order:
   1. `https://github.com/heroku/heroku-buildpack-apt`
   2. `heroku/python`
3. **Postgres** — Resources → Add-ons → Heroku Postgres (Essential-0 is enough).
4. **Config vars** — Settings → Config Vars (never commit these):

```
KEEPER_PRIVATE_KEY
DRY_RUN=true
MODEL_ID=eth-1-2-8h-v1
MODEL_8H_URL          # HTTPS file for eth_8h_lgbm.pkl, or git-add the pickle
UNISWAP_API_KEY       # optional; x-api-key for Uniswap LP pool_info on Arbitrum
FRONTEND_ORIGIN       # your Vercel URL; preview *.vercel.app is already allowed
```

5. **Clock dyno** — Resources: turn **web** and **clock** both on (`clock=1`). Web alone will not run hourly infer.
6. Open the app: `https://argon-XXXX.herokuapp.com/health`

### CLI equivalent

```bash
heroku login
heroku git:remote -a argon
heroku buildpacks:add https://github.com/heroku/heroku-buildpack-apt
heroku buildpacks:add heroku/python
heroku addons:create heroku-postgresql:essential-0
heroku config:set DRY_RUN=true MODEL_ID=eth-1-2-8h-v1
heroku ps:scale web=1 clock=1
heroku logs --tail
```

`web` serves GET APIs. `clock` sleeps until the next UTC hour and runs infer. Eco dynos sleep if you only scale `web` — **you need `clock=1`** or the hourly job never runs.

If you put the pickle in `agent/models/eth_8h_lgbm.pkl` instead of `MODEL_8H_URL`, force-add it (it is gitignored):

```bash
git add -f agent/models/eth_8h_lgbm.pkl
```

Go-live checklist:

1. `curl https://argon-agent-….herokuapp.com/health` → `"modelLoaded": true`
2. `curl …/forecasts/latest` → three percents + `forecastHash`
3. Flip `DRY_RUN=false` only after a dry tick looks right.
4. Confirm the keeper address on-chain is this key: `cast call $REGISTRY "keeper()(address)" --rpc-url $ARB_RPC`
5. Fund the keeper with a few dollars of ETH on Arb **and** Robinhood.
6. After 9 successful submits, `warmupComplete` becomes true and `rebalance` can ENTER/EXIT.

Heroku Scheduler (`0 * * * * python infer_once.py`) can replace the clock dyno if you want to save a process.

## Link the Vercel frontend

1. Create the Next.js app (or continue `apps/web`) with wagmi + the files above.
2. In the Vercel project: **Settings → Environment Variables**

```
NEXT_PUBLIC_AGENT_URL=https://argon-agent-XXXX.herokuapp.com
NEXT_PUBLIC_ARB_RPC=https://arb1.arbitrum.io/rpc
NEXT_PUBLIC_RH_RPC=https://rpc.mainnet.chain.robinhood.com
NEXT_PUBLIC_VAULT_ARB=0xe0eb546A1F8dcEc7B124cF8fE253de34d54A6c61
NEXT_PUBLIC_REGISTRY_ARB=0x8F288a7a6E28a5d44980De19502522C376965afe
NEXT_PUBLIC_VAULT_RH=0x89403CA4AdB3A89A0173B7494903B4247881966f
NEXT_PUBLIC_REGISTRY_RH=0x256A61b459BFdb48B4C04DE5Ba13E0dFBC326508
NEXT_PUBLIC_WALLETCONNECT_ID=
```

3. Deploy. Copy the production URL.
4. `heroku config:set FRONTEND_ORIGIN=https://your-app.vercel.app`
5. Poll `/forecasts/latest` every 30–60s (and around `:01` UTC). It **404s** unless Postgres has a row for the current UTC hour — do not fall back to `/forecasts` history (that was serving yesterday as live). If Heroku is down, show the last on-chain `getForecast` and a banner — do not invent a %.

Do **not** put `KEEPER_PRIVATE_KEY` or `TIINGO_API_KEY` in Vercel.

## Layout

```
agent/
  app.py                 FastAPI GET /health /status /forecasts
  clock.py               UTC-hour loop
  infer_once.py          one-shot (Scheduler / local)
  Procfile               web + clock
  requirements.txt
  argon_agent/
    infer.py             pickle + features
    policy.py            DualHorizonGate
    tick_job.py          infer → db → submit → rebalance
    chain.py             web3 keeper
    db.py                Postgres / sqlite
  models/                eth_8h_lgbm.pkl (you add this)
apps/web/lib/            Vercel client + ABIs
```

## Safety

- The keeper can only call `submit` and `rebalance`. It cannot withdraw user funds to an arbitrary address.
- The vault re-runs the gate; a buggy agent cannot ENTER into an EXIT signal.
- Pause is owner-only on the vault. Idle (and flatten-then-pro-rata) withdraw stays available to users.
- `DRY_RUN=true` is the default in `app.json` so a first push cannot spend gas until you unset it.

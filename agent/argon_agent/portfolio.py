"""Read-only vault balances for the frontend. No keeper key required."""

from __future__ import annotations

import logging
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from typing import Callable, TypeVar

from web3 import Web3

from argon_agent.abis import ADAPTER_ABI, ERC20_ABI, ORACLE_ABI, VAULT_ABI
from argon_agent.accounting import pro_rata, usd8_from_stable, usd8_from_weth, usd8_to_float
from argon_agent.config import ChainCfg, chains

log = logging.getLogger("argon.portfolio")

RPC_TIMEOUT_SECONDS = float(os.getenv("PORTFOLIO_RPC_TIMEOUT_SECONDS", "8"))
SHARED_CACHE_SECONDS = float(os.getenv("PORTFOLIO_CACHE_SECONDS", "12"))

_T = TypeVar("_T")
_cache_guard = threading.Lock()
_base_cache: dict[tuple, tuple[float, dict]] = {}
_base_locks: dict[tuple, threading.Lock] = {}


def _w3(cfg: ChainCfg) -> Web3:
    return Web3(Web3.HTTPProvider(cfg.rpc, request_kwargs={"timeout": RPC_TIMEOUT_SECONDS}))


def _parallel(calls: dict[str, Callable[[], _T]]) -> dict[str, _T]:
    """Resolve independent RPC calls together instead of paying their latency serially."""
    if not calls:
        return {}
    with ThreadPoolExecutor(max_workers=len(calls), thread_name_prefix="argon-rpc") as pool:
        futures = {pool.submit(fn): name for name, fn in calls.items()}
        return {futures[future]: future.result() for future in as_completed(futures)}


def _cache_key(cfg: ChainCfg) -> tuple:
    # Include every address that can change across a redeploy so stale entries cannot cross configurations.
    return (cfg.chain_id, cfg.rpc, cfg.vault, cfg.adapter, cfg.pool_id)


def _chain_lock(key: tuple) -> threading.Lock:
    with _cache_guard:
        return _base_locks.setdefault(key, threading.Lock())


def _read_chain_base(cfg: ChainCfg) -> dict:
    """Read chain-wide vault state. This result is safe to share between users briefly."""
    w3 = _w3(cfg)
    vault = w3.eth.contract(address=Web3.to_checksum_address(cfg.vault), abi=VAULT_ABI)

    first = _parallel(
        {
            "weth": lambda: vault.functions.weth().call(),
            "stable": lambda: vault.functions.stable().call(),
            "decimals": lambda: vault.functions.stableDecimals().call(),
            "oracle": lambda: vault.functions.oracle().call(),
            "pool": lambda: vault.functions.pools(cfg.pool_id).call(),
            "supply": lambda: vault.functions.totalShares().call(),
        }
    )
    weth = Web3.to_checksum_address(first["weth"])
    stable = Web3.to_checksum_address(first["stable"])
    decimals = int(first["decimals"])
    oracle = w3.eth.contract(address=Web3.to_checksum_address(first["oracle"]), abi=ORACLE_ABI)
    weth_c = w3.eth.contract(address=weth, abi=ERC20_ABI)
    stable_c = w3.eth.contract(address=stable, abi=ERC20_ABI)

    balances = _parallel(
        {
            "eth_usd8": lambda: oracle.functions.ethUsd8().call(),
            "idle_weth": lambda: weth_c.functions.balanceOf(vault.address).call(),
            "idle_stable": lambda: stable_c.functions.balanceOf(vault.address).call(),
        }
    )
    eth_usd8 = int(balances["eth_usd8"])
    idle_weth = int(balances["idle_weth"])
    idle_stable = int(balances["idle_stable"])

    lp_weth = 0
    lp_stable = 0
    in_pool = False
    try:
        adapter_addr, _gated, exists, _ex, _rb = first["pool"]
        if not exists or int(adapter_addr, 16) == 0:
            adapter_addr = cfg.adapter
        adapter = w3.eth.contract(address=Web3.to_checksum_address(adapter_addr), abi=ADAPTER_ABI)
        in_pool = bool(adapter.functions.inPosition().call())
        if in_pool:
            position = _parallel(
                {
                    "token_a": lambda: adapter.functions.tokenA().call(),
                    "token_b": lambda: adapter.functions.tokenB().call(),
                    "amounts": lambda: adapter.functions.amounts().call(),
                }
            )
            amt_a, amt_b = position["amounts"]
            for token, amount in (
                (Web3.to_checksum_address(position["token_a"]), int(amt_a)),
                (Web3.to_checksum_address(position["token_b"]), int(amt_b)),
            ):
                if token.lower() == weth.lower():
                    lp_weth += amount
                elif token.lower() == stable.lower():
                    lp_stable += amount
    except Exception:
        # Portfolio accounting can still return the idle balance if an adapter read is unavailable.
        log.exception("pool/adapter read failed on %s", cfg.name)

    total_usd8 = usd8_from_weth(idle_weth + lp_weth, eth_usd8) + usd8_from_stable(
        idle_stable + lp_stable, decimals
    )
    return {
        "name": cfg.name,
        "chainId": cfg.chain_id,
        "vault": cfg.vault,
        "poolId": cfg.pool_id,
        "pair": "WETH/USDC" if cfg.name == "arbitrum" else "WETH/USDG",
        "inPool": in_pool,
        "ethUsd": eth_usd8 / 1e8,
        "totalShares": str(int(first["supply"])),
        "tvlUsd": usd8_to_float(total_usd8),
        "stableSymbol": "USDC" if cfg.name == "arbitrum" else "USDG",
        "stableDecimals": decimals,
        # Internal values used to add a user's balances without repeating shared reads.
        "_weth": weth,
        "_stable": stable,
        "_total_usd8": total_usd8,
        "_supply": int(first["supply"]),
    }


def _chain_base(cfg: ChainCfg) -> dict:
    """Short TTL + per-chain single-flight prevents overlapping polls from stampeding public RPCs."""
    key = _cache_key(cfg)
    now = time.monotonic()
    with _cache_guard:
        cached = _base_cache.get(key)
        if cached and cached[0] > now:
            return dict(cached[1])

    with _chain_lock(key):
        now = time.monotonic()
        with _cache_guard:
            cached = _base_cache.get(key)
            if cached and cached[0] > now:
                return dict(cached[1])
        value = _read_chain_base(cfg)
        with _cache_guard:
            _base_cache[key] = (time.monotonic() + SHARED_CACHE_SECONDS, dict(value))
        return value


def read_chain(cfg: ChainCfg, user: str | None) -> dict:
    base = _chain_base(cfg)
    w3 = _w3(cfg)
    vault = w3.eth.contract(address=Web3.to_checksum_address(cfg.vault), abi=VAULT_ABI)
    weth = base.pop("_weth")
    stable = base.pop("_stable")
    total_usd8 = int(base.pop("_total_usd8"))
    supply = int(base.pop("_supply"))
    decimals = int(base["stableDecimals"])
    weth_c = w3.eth.contract(address=weth, abi=ERC20_ABI)
    stable_c = w3.eth.contract(address=stable, abi=ERC20_ABI)
    shares = 0
    user_idle_weth = 0
    user_idle_stable = 0
    wallet_weth = 0
    wallet_stable = 0
    if user:
        user_c = Web3.to_checksum_address(user)
        user_values = _parallel(
            {
                "shares": lambda: vault.functions.shareBalance(user_c).call(),
                "idle_weth": lambda: vault.functions.idleBalance(user_c, weth).call(),
                "idle_stable": lambda: vault.functions.idleBalance(user_c, stable).call(),
                "wallet_weth": lambda: weth_c.functions.balanceOf(user_c).call(),
                "wallet_stable": lambda: stable_c.functions.balanceOf(user_c).call(),
            }
        )
        shares = int(user_values["shares"])
        user_idle_weth = int(user_values["idle_weth"])
        user_idle_stable = int(user_values["idle_stable"])
        wallet_weth = int(user_values["wallet_weth"])
        wallet_stable = int(user_values["wallet_stable"])
    user_usd8 = pro_rata(total_usd8, shares, supply)
    return {
        **base,
        "shares": str(shares),
        "shareUsd": usd8_to_float(user_usd8),
        "idleWeth": str(user_idle_weth),
        "idleStable": str(user_idle_stable),
        "idleWethFormatted": user_idle_weth / 1e18,
        "idleStableFormatted": user_idle_stable / 10**decimals,
        "walletWeth": str(wallet_weth),
        "walletStable": str(wallet_stable),
        "walletWethFormatted": wallet_weth / 1e18,
        "walletStableFormatted": wallet_stable / 10**decimals,
    }


def snapshot(user: str | None = None) -> dict:
    chains_out: dict[str, dict] = {}
    total = 0.0
    cfgs = [cfg for cfg in chains() if cfg.enabled]
    with ThreadPoolExecutor(max_workers=max(1, len(cfgs)), thread_name_prefix="argon-chain") as pool:
        futures = {pool.submit(read_chain, cfg, user): cfg for cfg in cfgs}
        for future in as_completed(futures):
            cfg = futures[future]
            try:
                row = future.result()
                chains_out[cfg.name] = row
                total += float(row["shareUsd"])
            except Exception as exc:
                log.exception("portfolio read failed on %s", cfg.name)
                chains_out[cfg.name] = {"name": cfg.name, "chainId": cfg.chain_id, "error": str(exc)}
    return {
        "address": Web3.to_checksum_address(user) if user else None,
        "updatedAt": datetime.now(timezone.utc).isoformat(),
        "pollSeconds": 10,
        "totalUsd": total,
        "chains": chains_out,
    }

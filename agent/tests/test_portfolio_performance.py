import threading
from types import SimpleNamespace

from argon_agent import portfolio


def _cfg(name: str, chain_id: int):
    return SimpleNamespace(
        name=name,
        chain_id=chain_id,
        rpc=f"https://{name}.invalid",
        vault=f"0x{chain_id:040x}",
        adapter=f"0x{chain_id + 1:040x}",
        pool_id=1,
        enabled=True,
    )


def test_chain_base_uses_short_ttl_cache(monkeypatch):
    cfg = _cfg("arbitrum", 42161)
    calls = 0

    def fake_read(_cfg):
        nonlocal calls
        calls += 1
        return {"name": _cfg.name, "marker": calls}

    with portfolio._cache_guard:
        portfolio._base_cache.clear()
        portfolio._base_locks.clear()
    monkeypatch.setattr(portfolio, "_read_chain_base", fake_read)
    monkeypatch.setattr(portfolio, "SHARED_CACHE_SECONDS", 30.0)

    first = portfolio._chain_base(cfg)
    second = portfolio._chain_base(cfg)

    assert calls == 1
    assert first == second == {"name": "arbitrum", "marker": 1}
    assert first is not second


def test_snapshot_reads_enabled_chains_concurrently(monkeypatch):
    cfgs = [_cfg("arbitrum", 42161), _cfg("robinhood", 4663)]
    rendezvous = threading.Barrier(2)

    def fake_read(cfg, _user):
        # This raises in a sequential implementation, making concurrency deterministic to test.
        rendezvous.wait(timeout=1)
        return {"name": cfg.name, "chainId": cfg.chain_id, "shareUsd": 1.25}

    monkeypatch.setattr(portfolio, "chains", lambda: cfgs)
    monkeypatch.setattr(portfolio, "read_chain", fake_read)

    result = portfolio.snapshot("0x0000000000000000000000000000000000000001")

    assert set(result["chains"]) == {"arbitrum", "robinhood"}
    assert all("error" not in row for row in result["chains"].values())
    assert result["totalUsd"] == 2.5


def test_snapshot_keeps_healthy_chain_when_other_rpc_fails(monkeypatch):
    cfgs = [_cfg("arbitrum", 42161), _cfg("robinhood", 4663)]

    def fake_read(cfg, _user):
        if cfg.name == "robinhood":
            raise TimeoutError("RPC timed out")
        return {"name": cfg.name, "chainId": cfg.chain_id, "shareUsd": 2.0}

    monkeypatch.setattr(portfolio, "chains", lambda: cfgs)
    monkeypatch.setattr(portfolio, "read_chain", fake_read)

    result = portfolio.snapshot(None)

    assert result["chains"]["arbitrum"]["shareUsd"] == 2.0
    assert result["chains"]["robinhood"]["error"] == "RPC timed out"
    assert result["totalUsd"] == 2.0

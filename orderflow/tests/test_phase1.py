"""Offline tests for Phase 1: order book, depth sync, trades, recorder + replay.

    cd orderflow && python -m pytest -q
"""
import asyncio
import gzip
import json
import sys
from pathlib import Path

import aiohttp
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from adapters.binance_futures import BinanceFuturesAdapter, StaleSnapshot, first_applicable  # noqa: E402
from core.events import BookDiff, BookSnapshot, StreamStatus, Trade  # noqa: E402
from core.orderbook import OrderBook  # noqa: E402
from core.recorder import Recorder  # noqa: E402
from core.replay import iter_events  # noqa: E402


# ---------------------------------------------------------------- order book
def test_orderbook_load_apply_and_imbalance():
    ob = OrderBook()
    ob.load([(100.0, 2.0), (99.0, 1.0), (98.0, 0.0)], [(101.0, 1.0), (102.0, 3.0)])
    assert ob.ready
    assert ob.best_bid() == 100.0 and ob.best_ask() == 101.0
    assert 98.0 not in ob.bids  # qty 0 is never stored
    ob.apply([(100.0, 0.0), (99.5, 4.0)], [(101.0, 0.0)])
    assert ob.best_bid() == 99.5 and ob.best_ask() == 102.0
    # bids 4 + 1 = 5, asks 3: (5 - 3) / 8
    assert ob.imbalance(10) == pytest.approx(0.25)


# ---------------------------------------------------------------- snapshot alignment
def test_first_applicable():
    ev = [{"U": 1, "u": 5}, {"U": 6, "u": 10}, {"U": 11, "u": 15}]
    assert first_applicable(ev, 8) == 1          # 6 <= 8 <= 10
    assert first_applicable(ev, 3) == 0
    assert first_applicable(ev, 20) is None      # buffer has not caught up yet
    with pytest.raises(StaleSnapshot):
        first_applicable([{"U": 12, "u": 15}], 8)  # updates 9..11 are missing


# ---------------------------------------------------------------- fake websocket
class _Msg:
    def __init__(self, payload: dict):
        self.type = aiohttp.WSMsgType.TEXT
        self.data = json.dumps({"data": payload})


class _FakeWS:
    def __init__(self, payloads):
        self.payloads = payloads

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    def __aiter__(self):
        return self._gen()

    async def _gen(self):
        for p in self.payloads:
            await asyncio.sleep(0)  # let the snapshot task run, as a real socket would
            yield _Msg(p)


class _FakeSession:
    def __init__(self, payloads):
        self.payloads = payloads

    def ws_connect(self, url, heartbeat=None):
        return _FakeWS(self.payloads)


def _diff(U, u, pu, bids=(), asks=()):
    return {"e": "depthUpdate", "E": u, "T": u, "U": U, "u": u, "pu": pu,
            "b": [[str(p), str(q)] for p, q in bids], "a": [[str(p), str(q)] for p, q in asks]}


def _drain(q: asyncio.Queue) -> list:
    out = []
    while not q.empty():
        out.append(q.get_nowait())
    return out


def test_depth_sync_and_resync_on_gap():
    diffs = [
        _diff(1, 5, 0, bids=[(90, 9)]),            # older than snapshot 1: dropped
        _diff(6, 10, 5, bids=[(100, 5)]),          # straddles snapshot 1 (lastUpdateId 8)
        _diff(11, 15, 10, asks=[(101, 0)]),        # removes a level
        _diff(16, 20, 15, bids=[(99, 2)]),
        _diff(30, 35, 29, bids=[(1, 1)]),          # gap: pu 29 != 20 -> resync
        _diff(36, 40, 35, asks=[(103, 7)]),        # straddles snapshot 2 (lastUpdateId 37)
        _diff(41, 45, 40, bids=[(100, 0)]),
        _diff(46, 50, 45, asks=[(104, 1)]),
    ]
    snaps = iter([
        {"lastUpdateId": 8, "T": 8, "bids": [["100", "1"]], "asks": [["101", "1"], ["102", "2"]]},
        {"lastUpdateId": 37, "T": 37, "bids": [["100", "3"], ["99", "1"]], "asks": [["102", "2"]]},
    ])

    async def run():
        q: asyncio.Queue = asyncio.Queue()
        a = BinanceFuturesAdapter("BTCUSDT", q)
        a._session = _FakeSession(diffs)

        async def fake_snapshot():
            return next(snaps)

        a._fetch_snapshot = fake_snapshot
        await a._depth()
        return a, _drain(q)

    adapter, events = asyncio.run(run())
    kinds = [type(e).__name__ if not isinstance(e, StreamStatus) else f"status:{e.status}" for e in events]
    assert kinds == ["status:up", "BookSnapshot", "BookDiff", "BookDiff", "BookDiff",
                     "status:resync", "BookSnapshot", "BookDiff", "BookDiff", "BookDiff"]
    assert adapter.stats["resyncs"] == 1
    # final book = snapshot 2 + diffs 36..50
    assert adapter.book.bids == {99.0: 1.0}
    assert adapter.book.asks == {102.0: 2.0, 103.0: 7.0, 104.0: 1.0}
    # a replica rebuilt only from the emitted events matches the adapter's book
    replica = OrderBook()
    for e in events:
        if isinstance(e, BookSnapshot):
            replica.load(e.bids, e.asks)
        elif isinstance(e, BookDiff):
            replica.apply(e.bids, e.asks)
    assert replica.bids == adapter.book.bids and replica.asks == adapter.book.asks


def test_trades_aggressor_side():
    payloads = [
        {"e": "aggTrade", "T": 1, "p": "100.5", "q": "0.2", "m": True, "a": 1},   # seller aggressed
        {"e": "aggTrade", "T": 2, "p": "100.6", "q": "0.1", "m": False, "a": 2},  # buyer aggressed
    ]

    async def run():
        q: asyncio.Queue = asyncio.Queue()
        a = BinanceFuturesAdapter("BTCUSDT", q)
        a._session = _FakeSession(payloads)
        await a._trades()
        return _drain(q)

    trades = [e for e in asyncio.run(run()) if isinstance(e, Trade)]
    assert [(t.side, t.price, t.qty, t.trade_id) for t in trades] == [("sell", 100.5, 0.2, 1), ("buy", 100.6, 0.1, 2)]


# ---------------------------------------------------------------- recorder + replay
def test_recorder_rotates_hourly_and_replays(tmp_path):
    book = OrderBook()
    rec = Recorder(tmp_path, "binance-usdm", "BTCUSDT", book, flush_seconds=0)
    h13 = 1_793_106_000_000  # 2026-10-27 13:00:00 UTC
    snap = BookSnapshot(h13 + 1, [(100.0, 1.0)], [(101.0, 1.0)])
    events = [
        snap,
        Trade(h13 + 2, 100.5, 0.3, "buy", 1),
        BookDiff(h13 + 3, [(100.0, 2.0)], []),
        StreamStatus(h13 + 4, "trades", "down", "test"),
        Trade(h13 + 3_600_000 + 5, 100.4, 0.1, "sell", 2),  # next hour
    ]
    for ev in events:
        rec.write(ev)  # before applying, as main.py does
        if isinstance(ev, BookSnapshot):
            book.load(ev.bids, ev.asks)
        elif isinstance(ev, BookDiff):
            book.apply(ev.bids, ev.asks)
    rec.close()

    files = sorted((tmp_path / "binance-usdm" / "BTCUSDT").glob("*/*.jsonl.gz"))
    assert [f"{f.parent.name}/{f.name}" for f in files] == ["2026-10-27/13.jsonl.gz", "2026-10-27/14.jsonl.gz"]
    with gzip.open(files[1], "rt") as fh:
        first = json.loads(fh.readline())
    assert first["k"] == "S" and first["b"] == [[100.0, 2.0]]  # 14:00 opens with the book as it was

    back = list(iter_events(tmp_path, "binance-usdm", "BTCUSDT"))
    assert back[:4] == events[:4]
    assert isinstance(back[4], BookSnapshot) and back[5] == events[4]
    assert list(iter_events(tmp_path, "binance-usdm", "BTCUSDT", start="2026-10-27/14"))[-1] == events[4]

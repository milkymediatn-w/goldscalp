"""Binance USD-M futures adapter: public trade + order book streams.

No account or API key needed. Uses the 2026 split endpoints:
  /market  -> aggTrade (trades)
  /public  -> depth    (order book diffs)
Order book sync follows Binance's documented procedure: buffer diffs,
fetch a REST snapshot, drop stale diffs, then require each diff's `pu`
to equal the previous diff's `u`. Any gap triggers a fresh resync.
"""
import asyncio
import json
import logging
import random
import time

import aiohttp

from core.events import BookDiff, BookSnapshot, StreamStatus, Trade
from core.orderbook import OrderBook

log = logging.getLogger("binance")

REST_BASE = "https://fapi.binance.com"
WS_MARKET = "wss://fstream.binance.com/market/stream?streams="
WS_PUBLIC = "wss://fstream.binance.com/public/stream?streams="
SNAPSHOT_LIMIT = 1000
MAX_BUFFER = 5000


class StaleSnapshot(Exception):
    """Snapshot is older than the buffered diffs; a new one is needed."""


def first_applicable(events: list[dict], last_update_id: int) -> int | None:
    """Index of the first buffered diff to apply on top of a snapshot.

    Returns None if no diff has caught up to the snapshot yet.
    Raises StaleSnapshot if updates between snapshot and buffer are missing.
    """
    for i, e in enumerate(events):
        if e["u"] < last_update_id:
            continue  # already contained in the snapshot
        if e["U"] <= last_update_id <= e["u"]:
            return i
        raise StaleSnapshot
    return None


def _levels(raw: list) -> list[tuple[float, float]]:
    return [(float(p), float(q)) for p, q in raw]


def _now_ms() -> int:
    return int(time.time() * 1000)


class BinanceFuturesAdapter:
    name = "binance-usdm"

    def __init__(self, symbol: str, out: asyncio.Queue, depth_speed: str = "100ms"):
        self.symbol = symbol.upper()
        s = symbol.lower()
        self.trade_stream = f"{s}@aggTrade"
        self.depth_stream = f"{s}@depth" if depth_speed == "250ms" else f"{s}@depth@{depth_speed}"
        self.out = out
        self.book = OrderBook()  # used only to validate the sync
        self.stats = {"reconnects": 0, "resyncs": 0}
        self._session: aiohttp.ClientSession | None = None

    async def run(self) -> None:
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=15, sock_read=60)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            self._session = session
            await asyncio.gather(
                self._keep_alive(self._trades, "trades"),
                self._keep_alive(self._depth, "depth"),
            )

    async def _keep_alive(self, fn, label: str) -> None:
        delay = 1.0
        while True:
            started = time.monotonic()
            try:
                await fn()
                detail = "connection closed"
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # network errors, bad data, failed snapshot
                detail = f"{type(exc).__name__}: {exc}"
            log.warning("%s stream down (%s)", label, detail)
            await self.out.put(StreamStatus(_now_ms(), label, "down", detail))
            self.stats["reconnects"] += 1
            if time.monotonic() - started > 60:
                delay = 1.0  # it was a healthy connection; reconnect fast
            await asyncio.sleep(delay + random.random())
            delay = min(delay * 2, 60)

    async def _trades(self) -> None:
        async with self._session.ws_connect(WS_MARKET + self.trade_stream, heartbeat=30) as ws:
            log.info("trades connected")
            await self.out.put(StreamStatus(_now_ms(), "trades", "up"))
            async for msg in ws:
                if msg.type != aiohttp.WSMsgType.TEXT:
                    if msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                        break
                    continue
                d = json.loads(msg.data).get("data", {})
                if d.get("e") != "aggTrade":
                    continue
                await self.out.put(Trade(
                    ts=d["T"],
                    price=float(d["p"]),
                    qty=float(d["q"]),
                    side="sell" if d["m"] else "buy",  # m=True: buyer was maker, seller aggressed
                    trade_id=d["a"],
                ))

    async def _fetch_snapshot(self) -> dict:
        url = f"{REST_BASE}/fapi/v1/depth"
        params = {"symbol": self.symbol, "limit": SNAPSHOT_LIMIT}
        async with self._session.get(url, params=params) as r:
            r.raise_for_status()
            return await r.json()

    async def _emit_diff(self, e: dict) -> None:
        bids, asks = _levels(e["b"]), _levels(e["a"])
        self.book.apply(bids, asks)
        await self.out.put(BookDiff(ts=e.get("T") or e["E"], bids=bids, asks=asks))

    async def _depth(self) -> None:
        async with self._session.ws_connect(WS_PUBLIC + self.depth_stream, heartbeat=30) as ws:
            log.info("depth connected")
            await self.out.put(StreamStatus(_now_ms(), "depth", "up"))
            buffer: list[dict] = []
            synced = False
            last_u: int | None = None
            snap_task: asyncio.Task | None = None
            try:
                async for msg in ws:
                    if msg.type != aiohttp.WSMsgType.TEXT:
                        if msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                            break
                        continue
                    e = json.loads(msg.data).get("data", {})
                    if e.get("e") != "depthUpdate":
                        continue

                    if synced:
                        if e["pu"] != last_u:  # missed an update -> rebuild
                            log.warning("depth gap (pu=%s, expected %s); resyncing", e["pu"], last_u)
                            self.stats["resyncs"] += 1
                            await self.out.put(StreamStatus(_now_ms(), "depth", "resync", "sequence gap"))
                            synced, buffer, snap_task = False, [e], None
                            continue
                        await self._emit_diff(e)
                        last_u = e["u"]
                        continue

                    # --- not synced: buffer diffs until a snapshot lines up ---
                    buffer.append(e)
                    if len(buffer) > MAX_BUFFER:
                        buffer = buffer[-MAX_BUFFER:]
                    if snap_task is None:
                        snap_task = asyncio.create_task(self._fetch_snapshot())
                    if not snap_task.done():
                        continue
                    snap = snap_task.result()  # raises if the REST call failed
                    try:
                        idx = first_applicable(buffer, snap["lastUpdateId"])
                    except StaleSnapshot:
                        snap_task = None  # fetch a newer snapshot
                        continue
                    if idx is None:
                        continue  # wait for diffs to catch up

                    bids, asks = _levels(snap["bids"]), _levels(snap["asks"])
                    self.book.load(bids, asks)
                    await self.out.put(BookSnapshot(ts=snap.get("T") or _now_ms(), bids=bids, asks=asks))
                    last_u = None
                    ok = True
                    for be in buffer[idx:]:
                        if last_u is not None and be["pu"] != last_u:
                            ok = False
                            break
                        await self._emit_diff(be)
                        last_u = be["u"]
                    if ok:
                        synced, buffer = True, []
                        log.info("order book synced (%d bids / %d asks)", len(self.book.bids), len(self.book.asks))
                    else:
                        self.stats["resyncs"] += 1
                        buffer, snap_task = [], None
            finally:
                if snap_task and not snap_task.done():
                    snap_task.cancel()

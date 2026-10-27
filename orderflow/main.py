"""Phase 1: connect to live order flow, record it, report to Telegram.

Run:  python main.py
Stop: Ctrl+C
"""
import asyncio
import html
import logging
import time

import aiohttp

from adapters.binance_futures import BinanceFuturesAdapter
from config import Config
from core.events import BookDiff, BookSnapshot, StreamStatus, Trade
from core.orderbook import OrderBook
from core.recorder import Recorder
from core.telegram import TelegramNotifier

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("main")


class WindowStats:
    """Order-flow summary for the current heartbeat window."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.trades = 0
        self.buy_vol = 0.0
        self.sell_vol = 0.0
        self.high: float | None = None
        self.low: float | None = None
        self.last: float | None = None
        self.started = time.time()

    def add(self, t: Trade) -> None:
        self.trades += 1
        if t.side == "buy":
            self.buy_vol += t.qty
        else:
            self.sell_vol += t.qty
        self.last = t.price
        self.high = t.price if self.high is None else max(self.high, t.price)
        self.low = t.price if self.low is None else min(self.low, t.price)


async def consume(q: asyncio.Queue, book: OrderBook, recorder: Recorder | None,
                  stats: WindowStats) -> None:
    while True:
        ev = await q.get()
        if recorder:
            recorder.write(ev)  # before applying, so hourly snapshots stay consistent
        if isinstance(ev, Trade):
            stats.add(ev)
        elif isinstance(ev, BookDiff):
            book.apply(ev.bids, ev.asks)
        elif isinstance(ev, BookSnapshot):
            book.load(ev.bids, ev.asks)
        elif isinstance(ev, StreamStatus) and ev.status == "down":
            log.warning("stream %s down: %s", ev.stream, ev.detail)


def fmt(x: float | None, nd: int = 2) -> str:
    return "n/a" if x is None else f"{x:,.{nd}f}"


async def heartbeat(cfg: Config, book: OrderBook, stats: WindowStats, adapter: BinanceFuturesAdapter,
                    recorder: Recorder | None, tg: TelegramNotifier, q: asyncio.Queue) -> None:
    while True:
        await asyncio.sleep(cfg.heartbeat_minutes * 60)
        delta = stats.buy_vol - stats.sell_vol
        bb, ba = book.best_bid(), book.best_ask()
        spread = (ba - bb) if (bb is not None and ba is not None) else None
        imb = book.imbalance(10)
        rec = html.escape(str(recorder.current_path)) if recorder and recorder.current_path else "off"
        msg = (
            f"📊 <b>{cfg.symbol} — last {cfg.heartbeat_minutes} min</b>\n"
            f"Price: {fmt(stats.last)}  (H {fmt(stats.high)} / L {fmt(stats.low)})\n"
            f"Trades: {stats.trades:,}\n"
            f"Buy vol: {fmt(stats.buy_vol, 3)}  |  Sell vol: {fmt(stats.sell_vol, 3)}\n"
            f"Delta: {'+' if delta >= 0 else ''}{fmt(delta, 3)}\n"
            f"Spread: {fmt(spread)}  |  Top-10 imbalance: {fmt(imb, 2)}\n"
            f"Reconnects: {adapter.stats['reconnects']}  |  Resyncs: {adapter.stats['resyncs']}  |  Queue: {q.qsize()}\n"
            f"Recording: {rec}"
        )
        await tg.send(msg)
        stats.reset()


async def main() -> None:
    cfg = Config()
    q: asyncio.Queue = asyncio.Queue(maxsize=200_000)
    adapter = BinanceFuturesAdapter(cfg.symbol, q, cfg.depth_speed)
    book = OrderBook()
    recorder = Recorder(cfg.data_dir, adapter.name, cfg.symbol, book) if cfg.record else None
    stats = WindowStats()

    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=15)) as http:
        tg = TelegramNotifier(cfg.telegram_token, cfg.telegram_chat_id, http)
        await tg.send(
            f"✅ <b>Order-flow bot online</b>\n"
            f"Source: Binance USDⓈ-M futures, {cfg.symbol}\n"
            f"Depth: {cfg.depth_speed}  |  Recording: {'on' if recorder else 'off'}\n"
            f"Summary every {cfg.heartbeat_minutes} min."
        )
        try:
            await asyncio.gather(
                adapter.run(),
                consume(q, book, recorder, stats),
                heartbeat(cfg, book, stats, adapter, recorder, tg, q),
            )
        finally:
            if recorder:
                recorder.close()
            try:
                await asyncio.shield(tg.send("⏹ Order-flow bot stopped."))
            except Exception:
                pass


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("stopped by user")

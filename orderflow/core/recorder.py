"""Records every event to compressed JSON-lines files, one per UTC hour:
    data/<source>/<SYMBOL>/<YYYY-MM-DD>/<HH>.jsonl.gz
Each hourly file starts with a book snapshot, so any hour can be replayed
on its own. Row kinds: t=trade, S=book snapshot, d=book diff, x=stream status.
"""
import gzip
import json
import logging
import time
from pathlib import Path

from .events import BookDiff, BookSnapshot, StreamStatus, Trade
from .orderbook import OrderBook

log = logging.getLogger("recorder")


def encode(ev) -> dict:
    if isinstance(ev, Trade):
        return {"k": "t", "ts": ev.ts, "p": ev.price, "q": ev.qty, "s": ev.side[0], "id": ev.trade_id}
    if isinstance(ev, BookDiff):
        return {"k": "d", "ts": ev.ts, "b": ev.bids, "a": ev.asks}
    if isinstance(ev, BookSnapshot):
        return {"k": "S", "ts": ev.ts, "b": ev.bids, "a": ev.asks}
    if isinstance(ev, StreamStatus):
        return {"k": "x", "ts": ev.ts, "stream": ev.stream, "status": ev.status, "detail": ev.detail}
    raise TypeError(f"unknown event {type(ev)}")


class Recorder:
    def __init__(self, base: Path, source: str, symbol: str, book: OrderBook, flush_seconds: float = 5.0):
        self.dir = Path(base) / source / symbol.upper()
        self.book = book  # the consumer's book, used to start each hour with a snapshot
        self.flush_seconds = flush_seconds
        self._fh = None
        self._hour: str | None = None
        self._last_flush = time.monotonic()
        self.current_path: Path | None = None

    def write(self, ev) -> None:
        """Call BEFORE the event is applied to the book."""
        hour = time.strftime("%Y-%m-%d/%H", time.gmtime(ev.ts / 1000))
        if hour != self._hour:
            self._rotate(hour, ev.ts)
        self._fh.write(json.dumps(encode(ev), separators=(",", ":")) + "\n")
        if time.monotonic() - self._last_flush > self.flush_seconds:
            self._fh.flush()
            self._last_flush = time.monotonic()

    def _rotate(self, hour: str, ts: int) -> None:
        self.close()
        path = self.dir / f"{hour}.jsonl.gz"
        path.parent.mkdir(parents=True, exist_ok=True)
        self._fh = gzip.open(path, "at", encoding="utf-8")
        self._hour = hour
        self.current_path = path
        log.info("recording to %s", path)
        if self.book.ready:
            bids, asks = self.book.snapshot()
            self._fh.write(json.dumps(encode(BookSnapshot(ts, bids, asks)), separators=(",", ":")) + "\n")

    def close(self) -> None:
        if self._fh:
            self._fh.close()
            self._fh = None

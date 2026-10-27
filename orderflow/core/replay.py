"""Read recorded files back as events, in time order, for backtesting."""
import gzip
import json
from pathlib import Path
from typing import Iterator

from .events import BookDiff, BookSnapshot, StreamStatus, Trade


def decode(row: dict):
    k = row["k"]
    if k == "t":
        return Trade(row["ts"], row["p"], row["q"], "buy" if row["s"] == "b" else "sell", row["id"])
    if k == "d":
        return BookDiff(row["ts"], [tuple(x) for x in row["b"]], [tuple(x) for x in row["a"]])
    if k == "S":
        return BookSnapshot(row["ts"], [tuple(x) for x in row["b"]], [tuple(x) for x in row["a"]])
    if k == "x":
        return StreamStatus(row["ts"], row["stream"], row["status"], row.get("detail", ""))
    raise ValueError(f"unknown row kind {k}")


def iter_events(data_dir: Path, source: str, symbol: str,
                start: str | None = None, end: str | None = None) -> Iterator:
    """start/end as 'YYYY-MM-DD/HH' (inclusive), e.g. '2026-10-28/13'."""
    root = Path(data_dir) / source / symbol.upper()
    for path in sorted(root.glob("*/*.jsonl.gz")):
        key = f"{path.parent.name}/{path.name[:2]}"
        if (start and key < start) or (end and key > end):
            continue
        try:
            with gzip.open(path, "rt", encoding="utf-8") as fh:
                for line in fh:
                    if line.strip():
                        yield decode(json.loads(line))
        except EOFError:
            pass  # last file may be cut short if the bot was killed mid-write

"""Provider-neutral market events. Every data adapter (Binance now, a gold
provider later) converts its feed into these, so the engine never needs to
know where the data came from."""
from dataclasses import dataclass

Level = tuple[float, float]  # (price, quantity)


@dataclass(slots=True)
class Trade:
    ts: int          # exchange trade time, ms since epoch (UTC)
    price: float
    qty: float
    side: str        # aggressor: "buy" = lifted the ask, "sell" = hit the bid
    trade_id: int


@dataclass(slots=True)
class BookSnapshot:
    ts: int
    bids: list[Level]
    asks: list[Level]


@dataclass(slots=True)
class BookDiff:
    ts: int
    bids: list[Level]  # changed levels only; qty 0 means the level was removed
    asks: list[Level]


@dataclass(slots=True)
class StreamStatus:
    ts: int
    stream: str      # "trades" or "depth"
    status: str      # "up", "down", "resync"
    detail: str = ""

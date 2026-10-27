"""Local limit order book rebuilt from snapshots and diffs."""
from .events import Level


class OrderBook:
    def __init__(self) -> None:
        self.bids: dict[float, float] = {}
        self.asks: dict[float, float] = {}

    def load(self, bids: list[Level], asks: list[Level]) -> None:
        self.bids = {p: q for p, q in bids if q > 0}
        self.asks = {p: q for p, q in asks if q > 0}

    def apply(self, bids: list[Level], asks: list[Level]) -> None:
        for book, levels in ((self.bids, bids), (self.asks, asks)):
            for p, q in levels:
                if q == 0:
                    book.pop(p, None)
                else:
                    book[p] = q

    @property
    def ready(self) -> bool:
        return bool(self.bids) and bool(self.asks)

    def best_bid(self) -> float | None:
        return max(self.bids) if self.bids else None

    def best_ask(self) -> float | None:
        return min(self.asks) if self.asks else None

    def top(self, levels: int = 10) -> tuple[list[Level], list[Level]]:
        bids = sorted(self.bids.items(), key=lambda x: -x[0])[:levels]
        asks = sorted(self.asks.items(), key=lambda x: x[0])[:levels]
        return bids, asks

    def imbalance(self, levels: int = 10) -> float | None:
        """+1 = all resting size on the bid side, -1 = all on the ask side."""
        bids, asks = self.top(levels)
        b = sum(q for _, q in bids)
        a = sum(q for _, q in asks)
        return (b - a) / (b + a) if (a + b) else None

    def snapshot(self) -> tuple[list[Level], list[Level]]:
        return list(self.bids.items()), list(self.asks.items())

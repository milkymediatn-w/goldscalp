"""
Live BTC monitor that applies ScalpEngine v2's rules to Coinbase BTC-USD.

    python mt5/btc_live.py snapshot          # volume profile, order book, current state
    python mt5/btc_live.py live [minutes]    # watch candles, print setups and simulate exits

Coinbase marks every trade's aggressor side, so flow here is real taker buying vs
selling (the EA on an Exness CFD feed has to infer it from quote changes).
Costs use the Exness BTCUSDm spread (EXNESS_SPREAD), not Coinbase's.
Prices are Coinbase's: Exness quotes sit a few dollars away. Rule outputs only,
not trade advice.
"""
import sys
import time
from collections import deque
from datetime import datetime, timezone

import httpx
import pandas as pd

API = "https://api.exchange.coinbase.com/products/BTC-USD"
EXNESS_SPREAD = 6.40

# ScalpEngine v2 defaults
TF_SEC = 180
HTF = "15min"
HTF_EMA = 50
RANGE_BARS = 5
ENTRY_WINDOW = int(TF_SEC * 0.35)
FLOW_WINDOW = 30
MIN_FLOW = 0.25
MIN_SPEED_X = 1.3
MAX_CHASE_ATR = 0.4
IMPULSE_ATR = 1.2
IMPULSE_BODY = 0.6
ATR_LEN = 14
MIN_ATR_TO_SPREAD = 3.0
MAX_ATR_SPIKE_X = 3.0
SL_ATR = 0.6
SL_MIN_SPREADS = 3.0
BE_R = 0.5
TRAIL_START_R = 0.8
TRAIL_ATR = 0.5

client = httpx.Client(timeout=10, headers={"User-Agent": "goldscalp-monitor"})


def utc(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%H:%M:%S")


def get(path: str, **params):
    for attempt in range(3):
        try:
            r = client.get(API + path, params=params)
            r.raise_for_status()
            return r.json()
        except httpx.HTTPError:
            if attempt == 2:
                raise
            time.sleep(1 + attempt)


def candles_1m(pages: int = 3) -> pd.DataFrame:
    """Last pages x 300 one-minute candles (Coinbase caps a request at 300)."""
    raw, end = [], int(time.time()) // 60 * 60 + 60
    for _ in range(pages):
        start = end - 300 * 60
        raw += get("/candles", granularity=60,
                   start=datetime.fromtimestamp(start, timezone.utc).isoformat(),
                   end=datetime.fromtimestamp(end, timezone.utc).isoformat())
        end = start
    df = pd.DataFrame(raw, columns=["t", "low", "high", "open", "close", "volume"]).drop_duplicates("t")
    df["t"] = pd.to_datetime(df.t, unit="s", utc=True)
    return df.set_index("t").sort_index()[["open", "high", "low", "close", "volume"]]


def resample(df: pd.DataFrame, rule: str) -> pd.DataFrame:
    return df.resample(rule, origin="epoch", label="left", closed="left").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last", "volume": "sum"}).dropna()


def atr(df: pd.DataFrame, n: int) -> pd.Series:
    # MT5's iATR is a simple average of true range.
    pc = df.close.shift()
    tr = pd.concat([df.high - df.low, (df.high - pc).abs(), (df.low - pc).abs()], axis=1).max(axis=1)
    return tr.rolling(n).mean()


def volume_profile(df: pd.DataFrame, bin_size: float = 25.0) -> dict:
    """Spread each 1m candle's volume evenly over its range, then bucket."""
    bins: dict[float, float] = {}
    for _, c in df.iterrows():
        lo = int(c.low // bin_size) * bin_size
        hi = int(c.high // bin_size) * bin_size
        levels = [lo + k * bin_size for k in range(int((hi - lo) / bin_size) + 1)]
        for lv in levels:
            bins[lv] = bins.get(lv, 0.0) + c.volume / len(levels)
    prof = pd.Series(bins).sort_index()
    poc = prof.idxmax()
    total, area = prof.sum(), prof[poc]
    lo_i = hi_i = prof.index.get_loc(poc)
    while area < 0.7 * total and (lo_i > 0 or hi_i < len(prof) - 1):
        down = prof.iloc[lo_i - 1] if lo_i > 0 else -1
        up = prof.iloc[hi_i + 1] if hi_i < len(prof) - 1 else -1
        if up >= down:
            hi_i += 1
            area += up
        else:
            lo_i -= 1
            area += down
    inside = prof.iloc[lo_i:hi_i + 1]
    thin = inside[inside < inside.median() * 0.35]
    return {"poc": poc + bin_size / 2, "val": prof.index[lo_i], "vah": prof.index[hi_i] + bin_size,
            "lvn": [lv + bin_size / 2 for lv in thin.index], "profile": prof}


def book_read(band_pct: float = 0.25) -> dict:
    book = get("/book", level=2)
    bids = pd.DataFrame(book["bids"], columns=["p", "s", "n"]).astype(float)
    asks = pd.DataFrame(book["asks"], columns=["p", "s", "n"]).astype(float)
    mid = (bids.p.iloc[0] + asks.p.iloc[0]) / 2
    lo, hi = mid * (1 - band_pct / 100), mid * (1 + band_pct / 100)
    b, a = bids[bids.p >= lo], asks[asks.p <= hi]
    imb = (b.s.sum() - a.s.sum()) / max(b.s.sum() + a.s.sum(), 1e-9)
    near_b, near_a = bids[bids.p >= mid * 0.995], asks[asks.p <= mid * 1.005]
    return {"mid": mid, "imb": imb, "bid_btc": b.s.sum(), "ask_btc": a.s.sum(),
            "bid_walls": near_b.nlargest(3, "s")[["p", "s"]].values.tolist(),
            "ask_walls": near_a.nlargest(3, "s")[["p", "s"]].values.tolist()}


def snapshot() -> None:
    m1 = candles_1m()
    m3, m15 = resample(m1, "3min"), resample(m1, HTF)
    a3 = atr(m3, ATR_LEN)
    ema = m15.close.ewm(span=HTF_EMA, adjust=False).mean()
    vp = volume_profile(m1)
    bk = book_read()
    last = m1.close.iloc[-1]
    trend = "up" if m15.close.iloc[-2] > ema.iloc[-2] else "down"
    span = f"{m1.index[0]:%H:%M}-{m1.index[-1]:%H:%M} UTC"

    print(f"\n=== BTC-USD (Coinbase) {last:,.2f} at {datetime.now(timezone.utc):%Y-%m-%d %H:%M:%S} UTC ===")
    print(f"M3 ATR(14) {a3.iloc[-2]:.2f} = {a3.iloc[-2] / EXNESS_SPREAD:.1f}x the Exness spread "
          f"(gate needs {MIN_ATR_TO_SPREAD})")
    print(f"M15 trend vs EMA{HTF_EMA}: {trend} (close {m15.close.iloc[-2]:,.0f}, EMA {ema.iloc[-2]:,.0f})")
    rh = m3.high.iloc[-RANGE_BARS - 1:-1].max()
    rl = m3.low.iloc[-RANGE_BARS - 1:-1].min()
    print(f"Last {RANGE_BARS} closed M3 candles: range {rl:,.2f} - {rh:,.2f}")
    print(f"\nVolume profile {span}: POC {vp['poc']:,.0f} | value area {vp['val']:,.0f} - {vp['vah']:,.0f}")
    if vp["lvn"]:
        print("Thin (low-volume) levels inside value: " + ", ".join(f"{x:,.0f}" for x in vp["lvn"][:8]))
    where = ("above value (acceptance up or a fade back to VAH)" if last > vp["vah"] else
             "below value (acceptance down or a fade back to VAL)" if last < vp["val"] else
             "inside value (rotation: edges tend to hold)")
    print(f"Price is {where}")
    print(f"\nOrder book within +/-0.25%: bids {bk['bid_btc']:.2f} BTC vs asks {bk['ask_btc']:.2f} BTC "
          f"-> imbalance {bk['imb']:+.2f}")
    print("Largest bids within 0.5%: " + ", ".join(f"{p:,.0f} ({s:.2f})" for p, s in bk["bid_walls"]))
    print("Largest asks within 0.5%: " + ", ".join(f"{p:,.0f} ({s:.2f})" for p, s in bk["ask_walls"]))


class Live:
    def __init__(self) -> None:
        self.trades: deque = deque()          # (ts, price, size, +1 taker buy / -1 taker sell)
        self.seen = 0
        self.m1 = candles_1m()
        self.last_candles = time.time()
        self.signal_bar = None
        self.pos = None
        self.results: list[float] = []

    def poll_trades(self) -> None:
        rows = get("/trades", limit=1000)
        fresh = [r for r in rows if r["trade_id"] > self.seen]
        for r in sorted(fresh, key=lambda r: r["trade_id"]):
            ts = pd.Timestamp(r["time"]).timestamp()
            # Coinbase reports the MAKER side: a "sell" maker means the taker bought.
            self.trades.append((ts, float(r["price"]), float(r["size"]), 1 if r["side"] == "sell" else -1))
        if fresh:
            self.seen = max(r["trade_id"] for r in fresh)
        cutoff = time.time() - 900
        while self.trades and self.trades[0][0] < cutoff:
            self.trades.popleft()

    def flow(self, now: float) -> tuple[float, float, float]:
        recent = [t for t in self.trades if t[0] >= now - FLOW_WINDOW]
        base = [t for t in self.trades if now - FLOW_WINDOW - 600 <= t[0] < now - FLOW_WINDOW]
        buys = sum(1 for t in recent if t[3] > 0)
        imb = (2 * buys - len(recent)) / len(recent) if recent else 0.0
        rate = len(recent) / FLOW_WINDOW
        base_rate = len(base) / 600 if base else 0.0
        vol_delta = sum(t[2] * t[3] for t in recent)
        return imb, (rate / base_rate if base_rate else 0.0), vol_delta

    def bars(self):
        m3 = resample(self.m1, "3min")
        m15 = resample(self.m1, HTF)
        return m3, m15

    def evaluate(self, now: float, price: float) -> None:
        bar_start = int(now // TF_SEC) * TF_SEC
        if self.pos or self.signal_bar == bar_start or now - bar_start > ENTRY_WINDOW:
            return
        m3, m15 = self.bars()
        m3 = m3[m3.index < pd.Timestamp(bar_start, unit="s", tz="UTC")]
        if len(m3) < 101:
            return
        a = atr(m3, ATR_LEN).iloc[-1]
        a_slow = atr(m3, 100).iloc[-1]
        if a < MIN_ATR_TO_SPREAD * EXNESS_SPREAD or a > MAX_ATR_SPIKE_X * a_slow:
            return
        ema = m15.close.ewm(span=HTF_EMA, adjust=False).mean()
        closed15 = m15[m15.index <= pd.Timestamp(now - 900, unit="s", tz="UTC")]
        htf = 1 if closed15.close.iloc[-1] > ema.loc[closed15.index[-1]] else -1
        rh = m3.high.iloc[-RANGE_BARS:].max()
        rl = m3.low.iloc[-RANGE_BARS:].min()
        cur = [t[1] for t in self.trades if t[0] >= bar_start]
        bh, bl = (max(cur), min(cur)) if cur else (price, price)
        o1, h1, l1, c1 = m3.iloc[-1][["open", "high", "low", "close"]]
        imb, speed, delta = self.flow(now)
        chase = MAX_CHASE_ATR * a
        d, setup = 0, ""
        if speed >= MIN_SPEED_X:
            if price > rh and price - rh <= chase and imb >= MIN_FLOW and htf >= 0:
                d, setup = 1, "breakout"
            elif price < rl and rl - price <= chase and imb <= -MIN_FLOW and htf <= 0:
                d, setup = -1, "breakout"
        rng1 = h1 - l1
        if not d and rng1 >= IMPULSE_ATR * a and abs(c1 - o1) >= IMPULSE_BODY * rng1:
            mid1 = (h1 + l1) / 2
            if c1 > o1 and imb >= MIN_FLOW and price > mid1 and price - c1 <= chase and htf >= 0:
                d, setup = 1, "impulse"
            elif c1 < o1 and imb <= -MIN_FLOW and price < mid1 and c1 - price <= chase and htf <= 0:
                d, setup = -1, "impulse"
        if not d:
            if bh > rh and price < rh and rh - price <= chase and imb <= -MIN_FLOW:
                d, setup = -1, "sweep"
            elif bl < rl and price > rl and price - rl <= chase and imb >= MIN_FLOW:
                d, setup = 1, "sweep"
        if not d:
            return
        self.signal_bar = bar_start
        sl_dist = max(SL_ATR * a, SL_MIN_SPREADS * EXNESS_SPREAD)
        half = EXNESS_SPREAD / 2
        entry = price + half if d > 0 else price - half       # pay half the Exness spread
        stop = price - half - sl_dist if d > 0 else price + half + sl_dist
        r = abs(entry - stop)
        self.pos = dict(d=d, setup=setup, entry=entry, stop=stop, r=r, atr=a, bar=bar_start,
                        best=0.0, worst=0.0)
        print(f"\n>>> {utc(now)} SETUP {setup.upper()} {'BUY' if d > 0 else 'SELL'} | Coinbase {price:,.2f} "
              f"| est. Exness fill {entry:,.2f} | stop {stop:,.2f} (risk ${r:.2f}) | "
              f"flow {imb:+.2f}, delta {delta:+.3f} BTC, speed {speed:.1f}x, M15 {'up' if htf > 0 else 'down'} "
              f"| range {rl:,.2f}-{rh:,.2f}, ATR {a:.2f}", flush=True)

    def manage(self, now: float, price: float) -> None:
        p = self.pos
        if not p:
            return
        half = EXNESS_SPREAD / 2
        exit_px = price - half if p["d"] > 0 else price + half    # the side we would close on
        move = (exit_px - p["entry"]) * p["d"]
        p["best"], p["worst"] = max(p["best"], move), min(p["worst"], move)
        hit = (exit_px <= p["stop"]) if p["d"] > 0 else (exit_px >= p["stop"])
        why = "stop" if hit else ("candle close" if now >= p["bar"] + TF_SEC else "")
        if why:
            fill = p["stop"] if hit else exit_px
            r = (fill - p["entry"]) * p["d"] / p["r"]
            self.results.append(r)
            print(f"<<< {utc(now)} EXIT {p['setup']} ({why}) @ {fill:,.2f} | {r:+.2f}R "
                  f"(${r * p['r'] * 0.01:+.2f} on 0.01 lot) | best {p['best'] / p['r']:+.2f}R "
                  f"worst {p['worst'] / p['r']:+.2f}R | session {len(self.results)} trades "
                  f"{sum(self.results):+.2f}R", flush=True)
            self.pos = None
            return
        new = p["stop"]
        if move >= BE_R * p["r"]:
            new = max(new, p["entry"]) if p["d"] > 0 else min(new, p["entry"])
        if move >= TRAIL_START_R * p["r"]:
            trail = exit_px - TRAIL_ATR * p["atr"] * p["d"]
            new = max(new, trail) if p["d"] > 0 else min(new, trail)
        p["stop"] = new

    def run(self, minutes: float) -> None:
        end = time.time() + minutes * 60
        print(f"Watching BTC-USD on M3 for {minutes:.0f} min (ScalpEngine v2 rules, Exness spread "
              f"${EXNESS_SPREAD}). Setups print when they trigger; exits are simulated.", flush=True)
        last_status = 0
        while time.time() < end:
            try:
                self.poll_trades()
                if time.time() - self.last_candles > 20:
                    self.m1 = candles_1m()
                    self.last_candles = time.time()
            except httpx.HTTPError as e:
                print(f"feed error: {e}", flush=True)
                time.sleep(5)
                continue
            if not self.trades:
                time.sleep(2)
                continue
            now, price = time.time(), self.trades[-1][1]
            self.manage(now, price)
            self.evaluate(now, price)
            bar_start = int(now // TF_SEC) * TF_SEC
            if bar_start != last_status and now - bar_start >= ENTRY_WINDOW:
                last_status = bar_start
                m3, _ = self.bars()
                closed = m3[m3.index < pd.Timestamp(bar_start, unit="s", tz="UTC")]
                a = atr(closed, ATR_LEN).iloc[-1]
                imb, speed, delta = self.flow(now)
                rh = closed.high.iloc[-RANGE_BARS:].max()
                rl = closed.low.iloc[-RANGE_BARS:].min()
                state = "in trade" if self.pos else ("setup taken" if self.signal_bar == bar_start else "no setup")
                print(f"{utc(now)} {price:,.2f} | range {rl:,.0f}-{rh:,.0f} | ATR {a:.1f} "
                      f"({a / EXNESS_SPREAD:.1f}x spread) | flow {imb:+.2f} delta {delta:+.3f} "
                      f"| speed {speed:.1f}x | {state}", flush=True)
            time.sleep(2)
        n = len(self.results)
        if n:
            wins = sum(1 for r in self.results if r > 0)
            print(f"\nDone: {n} simulated trades, {wins} wins, {sum(self.results):+.2f}R total", flush=True)
        else:
            print("\nDone: no setups in this window.", flush=True)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "snapshot"
    if mode == "snapshot":
        snapshot()
    elif mode == "live":
        Live().run(float(sys.argv[2]) if len(sys.argv) > 2 else 30)
    else:
        sys.exit(__doc__)

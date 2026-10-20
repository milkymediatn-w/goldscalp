"""
Market data layer supporting Coinbase Spot (BTCUSD) and Yahoo Finance Spot (XAUUSD).
Returns closed candles indexed in UTC, plus live spread when available.
"""
import threading
import time
from dataclasses import dataclass
from typing import Optional

import httpx
import pandas as pd

from config import Config

_mt5_lock = threading.Lock()
_mt5_ready = False
_last_offset = 0.0


@dataclass
class Feed:
    df: pd.DataFrame
    spread: Optional[float]
    source: str


def _fetch_coinbase(cfg: Config, symbol: str = "BTCUSD") -> pd.DataFrame:
    """Direct fetch from Coinbase Spot API (Pure USD Spot, No API Key required)."""
    cb_symbol = "BTC-USD" if symbol.upper() in ("BTCUSD", "BTCUSDT") else symbol.upper()
    granularity = {1: 60, 5: 300, 15: 900, 60: 3600}[cfg.tf_min]

    r = httpx.get(
        f"https://api.exchange.coinbase.com/products/{cb_symbol}/candles",
        params={"granularity": granularity},
        timeout=10,
    )
    r.raise_for_status()
    raw = r.json()

    # Format Coinbase array [time, low, high, open, close, volume]
    data = []
    for row in raw:
        data.append({
            "datetime": pd.to_datetime(row[0], unit="s", utc=True),
            "open": float(row[3]),
            "high": float(row[2]),
            "low": float(row[1]),
            "close": float(row[4]),
            "volume": float(row[5]),
        })

    df = pd.DataFrame(data).set_index("datetime").sort_index()
    return df[["open", "high", "low", "close", "volume"]]


def _fetch_yf(cfg: Config, symbol: str = "XAUUSD") -> pd.DataFrame:
    import yfinance as yf
    yf_sym = "XAU=X" if symbol.upper() in ("XAUUSD", "GOLD") else symbol
    interval, period = {1: ("1m", "7d"), 5: ("5m", "30d"), 15: ("15m", "30d"), 60: ("60m", "120d")}[cfg.tf_min]
    df = yf.Ticker(yf_sym).history(period=period, interval=interval, auto_adjust=False)
    return df.rename(columns=str.lower)[["open", "high", "low", "close", "volume"]]


def get_candles(cfg: Config, symbol: str = "XAUUSD") -> Feed:
    src = cfg.data_source.lower()
    spread = None

    if symbol.upper() in ("BTCUSD", "BTCUSDT"):
        df = _fetch_coinbase(cfg, "BTCUSD")
        source_label = "coinbase-spot"
    elif symbol.upper() in ("XAUUSD", "GOLD"):
        df = _fetch_yf(cfg, "XAUUSD")
        source_label = "yfinance-spot"
    else:
        df = _fetch_yf(cfg, symbol)
        source_label = src

    df = df.astype(float)
    df.index = df.index.tz_localize("UTC") if df.index.tz is None else df.index.tz_convert("UTC")
    df = df[~df.index.duplicated()].sort_index().dropna()
    return Feed(df=df.iloc[:-1], spread=spread, source=source_label)
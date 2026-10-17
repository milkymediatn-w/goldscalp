"""
Market data layer supporting Binance Direct (BTCUSD), Yahoo Finance (XAUUSD),
Twelve Data, and MetaTrader 5.
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


def _fetch_binance(cfg: Config, symbol: str = "BTCUSD") -> pd.DataFrame:
    """Direct fetch from Binance spot API (No API Key required, zero daily limits)."""
    binance_symbol = "BTCUSDT" if symbol.upper() == "BTCUSD" else symbol.upper().replace("/", "").replace("USD", "USDT")
    interval = {1: "1m", 5: "5m", 15: "15m", 60: "1h"}[cfg.tf_min]

    r = httpx.get(
        "https://api.binance.com/api/v3/klines",
        params={"symbol": binance_symbol, "interval": interval, "limit": min(cfg.bars, 1000)},
        timeout=10,
    )
    r.raise_for_status()
    raw = r.json()

    # Format Binance array [open_time, open, high, low, close, volume, ...]
    data = []
    for row in raw:
        data.append({
            "datetime": pd.to_datetime(row[0], unit="ms", utc=True),
            "open": float(row[1]),
            "high": float(row[2]),
            "low": float(row[3]),
            "close": float(row[4]),
            "volume": float(row[5]),
        })

    df = pd.DataFrame(data).set_index("datetime").sort_index()
    return df[["open", "high", "low", "close", "volume"]]


def _fetch_yf(cfg: Config, symbol: str = "XAUUSD") -> pd.DataFrame:
    import yfinance as yf
    yf_sym = "GC=F" if symbol.upper() == "XAUUSD" else ("BTC-USD" if symbol.upper() == "BTCUSD" else symbol)
    interval, period = {1: ("1m", "7d"), 5: ("5m", "30d"), 15: ("15m", "30d"), 60: ("60m", "120d")}[cfg.tf_min]
    df = yf.Ticker(yf_sym).history(period=period, interval=interval, auto_adjust=False)
    return df.rename(columns=str.lower)[["open", "high", "low", "close", "volume"]]


def get_candles(cfg: Config, symbol: str = "XAUUSD") -> Feed:
    src = cfg.data_source.lower()
    spread = None

    if symbol.upper() in ("BTCUSD", "BTCUSDT"):
        # Always use Binance Direct for BTCUSD for maximum speed & reliability
        df = _fetch_binance(cfg, symbol)
        source_label = "binance"
    elif src == "yfinance" or src == "twelvedata":
        df = _fetch_yf(cfg, symbol)
        source_label = "yfinance"
    else:
        df = _fetch_yf(cfg, symbol)
        source_label = src

    df = df.astype(float)
    df.index = df.index.tz_localize("UTC") if df.index.tz is None else df.index.tz_convert("UTC")
    df = df[~df.index.duplicated()].sort_index().dropna()
    return Feed(df=df.iloc[:-1], spread=spread, source=source_label)
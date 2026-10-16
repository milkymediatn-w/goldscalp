"""
Market data layer supporting MetaTrader 5, Twelve Data, and Yahoo Finance.
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


def _mt5_offset(cfg: Config, tick) -> float:
    global _last_offset
    if cfg.mt5_utc_offset.strip():
        return float(cfg.mt5_utc_offset)
    if tick is not None:
        diff = tick.time - time.time()
        if abs(diff) <= 14 * 3600:
            _last_offset = float(round(diff / 3600))
    return _last_offset


def _fetch_mt5(cfg: Config, symbol: str = "XAUUSD"):
    global _mt5_ready
    try:
        import MetaTrader5 as mt5
    except ImportError as e:
        raise RuntimeError("MetaTrader5 package missing: pip install MetaTrader5") from e

    tf_map = {1: mt5.TIMEFRAME_M1, 5: mt5.TIMEFRAME_M5, 15: mt5.TIMEFRAME_M15, 60: mt5.TIMEFRAME_H1}
    if cfg.tf_min not in tf_map:
        raise ValueError("MT5 timeframe must be 1, 5, 15 or 60 minutes")

    sym = cfg.mt5_symbol if symbol.upper() == "XAUUSD" else symbol

    with _mt5_lock:
        if not _mt5_ready:
            kwargs = {}
            if cfg.mt5_path:
                kwargs["path"] = cfg.mt5_path
            if cfg.mt5_login:
                kwargs.update(login=int(cfg.mt5_login), password=cfg.mt5_password, server=cfg.mt5_server)
            if not mt5.initialize(**kwargs):
                raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")
            _mt5_ready = True

        if not mt5.symbol_select(sym, True):
            raise RuntimeError(f"MT5 symbol '{sym}' not found in Market Watch.")
        rates = mt5.copy_rates_from_pos(sym, tf_map[cfg.tf_min], 0, cfg.bars)
        if rates is None or len(rates) == 0:
            _mt5_ready = False
            mt5.shutdown()
            raise RuntimeError(f"MT5 returned no candles: {mt5.last_error()}")
        info = mt5.symbol_info(sym)
        tick = mt5.symbol_info_tick(sym)

    offset = _mt5_offset(cfg, tick)
    df = pd.DataFrame(rates)
    df.index = pd.to_datetime(df["time"] - int(offset * 3600), unit="s", utc=True)
    df["volume"] = df["tick_volume"].astype(float)
    spread = float(info.spread * info.point) if info is not None else None
    return df[["open", "high", "low", "close", "volume"]], spread


def _fetch_twelve(cfg: Config, symbol: str = "XAUUSD") -> pd.DataFrame:
    td_symbol = symbol
    if symbol.upper() == "XAUUSD":
        td_symbol = "XAU/USD"
    elif symbol.upper() == "BTCUSD":
        td_symbol = "BTC/USD"
    elif "/" not in symbol and symbol.endswith("USD"):
        td_symbol = symbol[:-3] + "/USD"

    interval = {1: "1min", 5: "5min", 15: "15min", 60: "1h"}[cfg.tf_min]
    r = httpx.get(
        "https://api.twelvedata.com/time_series",
        params={"symbol": td_symbol, "interval": interval, "outputsize": min(cfg.bars, 5000),
                "timezone": "UTC", "apikey": cfg.twelve_api_key},
        timeout=20,
    )
    j = r.json()
    if "values" not in j:
        raise RuntimeError(j.get("message", f"Twelve Data API error for {symbol}: {j}"))
    df = pd.DataFrame(j["values"])
    df["datetime"] = pd.to_datetime(df["datetime"], utc=True)
    df = df.set_index("datetime").sort_index()
    for col in ("open", "high", "low", "close"):
        df[col] = df[col].astype(float)
    df["volume"] = 0.0
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
    if src == "mt5":
        df, spread = _fetch_mt5(cfg, symbol)
    elif src == "twelvedata":
        df = _fetch_twelve(cfg, symbol)
    elif src == "yfinance":
        df = _fetch_yf(cfg, symbol)
    else:
        raise ValueError(f"Unknown DATA_SOURCE '{cfg.data_source}'")

    df = df.astype(float)
    df.index = df.index.tz_localize("UTC") if df.index.tz is None else df.index.tz_convert("UTC")
    df = df[~df.index.duplicated()].sort_index().dropna()
    return Feed(df=df.iloc[:-1], spread=spread, source=src)
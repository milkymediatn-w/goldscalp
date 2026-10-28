"""
Central configuration. Pick a PRESET in .env, then override any single
field by setting an env var with the same name in UPPER_CASE.
"""
import os
from dataclasses import dataclass, fields, replace


@dataclass
class Config:
    preset: str = "SCALP1M"

    # --- timeframes (minutes) ---
    tf_min: int = 1
    htf_min: int = 5
    htf_filter: bool = True

    # --- 8-EMA Ribbon Engine ---
    ema_lens: tuple = (5, 11, 15, 18, 21, 24, 28, 34)

    # --- Smart Money Concepts ---
    use_fvg_filter: bool = True
    fvg_min_atr: float = 0.20
    use_sweep_filter: bool = True

    # --- trend & sensitivity ---
    sensitivity: int = 7
    stability: int = 1

    # --- momentum ---
    rsi_len: int = 7
    rsi_ob: float = 75.0
    rsi_os: float = 25.0

    # --- risk model (ATR based) ---
    atr_len: int = 14
    sl_mult: float = 1.5
    tp1_mult: float = 1.5
    tp2_mult: float = 2.5
    tp3_mult: float = 4.0
    be_after_tp1: bool = True
    use_swing_sl: bool = True
    swing_lookback: int = 8

    # --- filters / housekeeping ---
    min_atr: float = 0.15
    min_score: int = 40          # Optimized floor for active signal generation
    cooldown_bars: int = 2
    expiry_bars: int = 60
    session_start: int = 0
    session_end: int = 24
    max_spread: float = 0.50
    assumed_spread: float = 0.30

    # --- data ---
    data_source: str = "yfinance"   # mt5 | yfinance
    bars: int = 3000
    mt5_symbol: str = "XAUUSDm"
    mt5_login: str = ""
    mt5_password: str = ""
    mt5_server: str = ""
    mt5_path: str = ""
    mt5_utc_offset: str = ""

    def summary(self) -> str:
        return (f"{self.preset} | {self.tf_min}m (HTF {self.htf_min}m) | 8-EMA Ribbon | "
                f"Score Floor {self.min_score} | SL {self.sl_mult}xATR | src {self.data_source}")


PRESETS = {
    "SCALP": dict(tf_min=5, htf_min=15, min_atr=0.5, cooldown_bars=6),
    "SCALP1M": dict(tf_min=1, htf_min=5, min_atr=0.15, cooldown_bars=2, bars=3000),
    "BALANCED": dict(tf_min=15, htf_min=60, min_atr=1.0, cooldown_bars=4),
    "MACRO": dict(tf_min=60, htf_min=240, min_atr=2.5, cooldown_bars=3),
}


def _cast(value: str, typ):
    if typ is bool:
        return value.strip().lower() in ("1", "true", "yes", "on")
    return typ(value)


def load_config() -> Config:
    name = os.getenv("PRESET", "SCALP1M").strip().upper()
    if name not in PRESETS:
        raise ValueError(f"Unknown PRESET '{name}'. Options: {', '.join(PRESETS)}")
    cfg = Config(preset=name, **PRESETS[name])
    overrides = {}
    for f in fields(cfg):
        if f.name == "preset":
            continue
        v = os.getenv(f.name.upper())
        if v not in (None, ""):
            overrides[f.name] = _cast(v, f.type)
    return replace(cfg, **overrides)
"""
Advanced Institutional Strategy Engine incorporating Volume Profile (POC, VAH, VAL),
Order Flow Delta, and Smart Money Concepts (CHoCH, FVG, Liquidity Sweeps, Premium/Discount).
"""
import numpy as np
import pandas as pd
from dataclasses import dataclass
from typing import Optional, Dict, Any

@dataclass
class SignalResult:
    action: Optional[str]  # 'BUY', 'SELL', or None
    score: int
    entry: float
    sl: float
    tp: float
    details: Dict[str, Any]

def calculate_atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    high_low = df['high'] - df['low']
    high_close = np.abs(df['high'] - df['close'].shift())
    low_close = np.abs(df['low'] - df['close'].shift())
    ranges = pd.concat([high_low, high_close, low_close], axis=1)
    true_range = np.max(ranges, axis=1)
    return true_range.rolling(period).mean()

def calculate_volume_profile(df: pd.DataFrame, bins: int = 30):
    """Calculates Point of Control (POC), Value Area High (VAH), and Value Area Low (VAL)."""
    if df.empty or len(df) < bins:
        return 0.0, 0.0, 0.0
    price_min = df['low'].min()
    price_max = df['high'].max()
    if price_min == price_max:
        return price_min, price_max, price_min
    
    counts, bin_edges = np.histogram(df['close'], bins=bins, weights=df['volume'])
    poc_idx = np.argmax(counts)
    poc_price = (bin_edges[poc_idx] + bin_edges[poc_idx + 1]) / 2.0
    
    total_volume = np.sum(counts)
    if total_volume == 0:
        return poc_price, price_max, price_min
        
    target_vol = total_volume * 0.70
    sorted_indices = np.argsort(counts)[::-1]
    cum_vol = 0
    selected_indices = []
    
    for idx in sorted_indices:
        cum_vol += counts[idx]
        selected_indices.append(idx)
        if cum_vol >= target_vol:
            break
            
    val_price = bin_edges[min(selected_indices)]
    vah_price = bin_edges[max(selected_indices) + 1]
    return float(poc_price), float(vah_price), float(val_price)

def analyze_order_flow(df: pd.DataFrame) -> pd.DataFrame:
    """Approximates candle-level buying/selling pressure and cumulative volume delta."""
    hl_range = df['high'] - df['low']
    hl_range = hl_range.replace(0, 0.0001)
    buy_pressure = (df['close'] - df['low']) / hl_range
    df['buy_vol'] = df['volume'] * buy_pressure
    df['sell_vol'] = df['volume'] * (1 - buy_pressure)
    df['delta'] = df['buy_vol'] - df['sell_vol']
    df['cum_delta'] = df['delta'].cumsum()
    return df

def evaluate_strategy(df: pd.DataFrame, htfr_df: Optional[pd.DataFrame] = None) -> SignalResult:
    if df is None or len(df) < 50:
        return SignalResult(None, 0, 0.0, 0.0, 0.0, {})

    df = analyze_order_flow(df.copy())
    atr = calculate_atr(df).iloc[-1]
    current_price = float(df['close'].iloc[-1])
    
    # Volume Profile over recent window
    poc, vah, val = calculate_volume_profile(df.tail(100))
    
    # Equilibrium (Premium vs Discount Zone)
    recent_high = df['high'].tail(50).max()
    recent_low = df['low'].tail(50).min()
    equilibrium = (recent_high + recent_low) / 2.0
    is_discount = current_price < equilibrium
    is_premium = current_price > equilibrium

    # Fair Value Gaps (FVG)
    bullish_fvg = (df['low'].iloc[-1] > df['high'].iloc[-3]) if len(df) >= 3 else False
    bearish_fvg = (df['high'].iloc[-1] < df['low'].iloc[-3]) if len(df) >= 3 else False

    # Liquidity Sweeps (Stop Hunts)
    prev_swing_high = df['high'].iloc[-20:-1].max()
    prev_swing_low = df['low'].iloc[-20:-1].min()
    bullish_sweep = (df['low'].iloc[-1] < prev_swing_low) and (current_price > prev_swing_low)
    bearish_sweep = (df['high'].iloc[-1] > prev_swing_high) and (current_price < prev_swing_high)

    # Change of Character (CHoCH)
    bullish_choch = current_price > prev_swing_high
    bearish_choch = current_price < prev_swing_low

    # Scoring Matrix
    bull_score = 0
    bear_score = 0
    details = []

    # 1. Volume Profile Confluence
    if current_price <= val and is_discount:
        bull_score += 25
        details.append("Price below VAL (Discount Zone / Accumulation)")
    elif current_price >= vah and is_premium:
        bear_score += 25
        details.append("Price above VAH (Premium Zone / Distribution)")
    elif abs(current_price - poc) < (atr * 0.5):
        details.append("Price testing Point of Control (POC Magnet)")

    # 2. Order Flow Delta Pressure
    recent_delta = df['delta'].iloc[-3:].sum()
    if recent_delta > 0:
        bull_score += 15
        details.append("Positive Volume Delta (Institutional Buying)")
    else:
        bear_score += 15
        details.append("Negative Volume Delta (Institutional Selling)")

    # 3. Smart Money Concepts (SMC)
    if bullish_sweep:
        bull_score += 25
        details.append("Bullish Liquidity Sweep (Stop Hunt below lows)")
    if bearish_sweep:
        bear_score += 25
        details.append("Bearish Liquidity Sweep (Stop Hunt above highs)")

    if bullish_fvg:
        bull_score += 15
        details.append("Bullish Fair Value Gap (FVG) Imbalance")
    if bearish_fvg:
        bear_score += 15
        details.append("Bearish Fair Value Gap (FVG) Imbalance")

    if bullish_choch:
        bull_score += 20
        details.append("Bullish Change of Character (CHoCH)")
    if bearish_choch:
        bear_score += 20
        details.append("Bearish Change of Character (CHoCH)")

    # Final Evaluation (Score Floor 40)
    action = None
    score = 0
    sl = 0.0
    tp = 0.0

    if bull_score >= 40 and bull_score > bear_score:
        action = 'BUY'
        score = bull_score
        sl = current_price - (1.5 * atr)
        tp = current_price + (2.5 * atr)
    elif bear_score >= 40 and bear_score > bull_score:
        action = 'SELL'
        score = bear_score
        sl = current_price + (1.5 * atr)
        tp = current_price - (2.5 * atr)

    return SignalResult(
        action=action,
        score=min(score, 100),
        entry=current_price,
        sl=round(sl, 2),
        tp=round(tp, 2),
        details={"notes": details, "poc": round(poc, 2), "vah": round(vah, 2), "val": round(val, 2)}
    )
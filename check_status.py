from config import load_config
from data import get_candles
from strategy import prepare

cfg = load_config()
print(f"Connecting to source: {cfg.data_source} for {cfg.mt5_symbol if cfg.data_source == 'mt5' else 'GC=F'}...")
feed = get_candles(cfg)
d = prepare(feed.df, cfg)
row = d.iloc[-1]

print("\n--- LIVE MARKET TELEMETRY ---")
print(f"Latest Closed Bar Time : {d.index[-1]}")
print(f"Current ATR            : {row['atr']:.2f} (Min Required: {cfg.min_atr})")
print(f"Current RSI            : {row['rsi']:.2f}")
print(f"8-EMA Ribbon Strength  : {row['ribbon_strength']*100:.0f}%")
print(f"Supertrend Direction   : {row['st_dir']}")
print(f"Higher-Timeframe Trend : {row['htf_dir']}")
print(f"Bullish FVG Trigger    : {row['bull_fvg']}")
print(f"Bearish FVG Trigger    : {row['bear_fvg']}")
print(f"Bullish Sweep Trigger  : {row['bull_sweep']}")
print(f"Bearish Sweep Trigger  : {row['bear_sweep']}")
print("-----------------------------\n")
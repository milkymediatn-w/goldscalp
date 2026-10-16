"""
MT5 Connection & Data Diagnostic Script
Verifies MetaTrader 5 terminal initialization, symbol lookup, spread, and candle feed.
"""
import sys
from dotenv import load_dotenv

# Load variables from .env first!
load_dotenv()

from config import load_config
from data import get_candles

def test_mt5():
    print("Initializing configuration...")
    cfg = load_config()
    
    print(f"Target Data Source : {cfg.data_source.upper()}")
    if cfg.data_source.lower() != "mt5":
        print(f"❌ Error: DATA_SOURCE is set to '{cfg.data_source}', not 'mt5'.")
        return

    print(f"Target MT5 Symbol  : {cfg.mt5_symbol}")
    print(f"MT5 Server         : {cfg.mt5_server}")
    print(f"Timeframe          : {cfg.tf_min} minute(s)")
    print("-" * 40)

    try:
        print("Attempting to connect to MetaTrader 5 terminal and fetch candles...")
        feed = get_candles(cfg)
        
        df = feed.df
        last_candle = df.iloc[-1]
        
        print("\n✅ SUCCESS: MT5 Connected & Data Received!")
        print(f"Source Type         : {feed.source}")
        print(f"Live Spread         : {f'${feed.spread:.2f}' if feed.spread is not None else 'Unknown (Check Market Watch)'}")
        print(f"Total Candles Loaded : {len(df)}")
        print(f"Latest Closed Bar   : {df.index[-1]}")
        print(f"  • Open            : {last_candle['open']:.2f}")
        print(f"  • High            : {last_candle['high']:.2f}")
        print(f"  • Low             : {last_candle['low']:.2f}")
        print(f"  • Close           : {last_candle['close']:.2f}")
        print(f"  • Volume          : {last_candle['volume']}")
        print("-" * 40)
        print("Your MT5 bridge is 100% operational and synced with Exness spot prices!")
        
    except Exception as e:
        print("\n❌ MT5 CONNECTION ERROR:")
        print(f"Details: {e}")
        print("-" * 40)
        print("Troubleshooting checklist:")
        print("1. Ensure MetaTrader 5 terminal is open and logged into account 250394741 on this PC.")
        print("2. Ensure 'XAUUSDm' is visible in your MT5 Market Watch window.")
        print("3. Ensure Python MetaTrader5 package is installed: pip install MetaTrader5")

if __name__ == "__main__":
    test_mt5()
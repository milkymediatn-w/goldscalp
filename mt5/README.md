# ScalpEngine: 1m order-flow scalper for MT5 (Exness)

An Expert Advisor that trades 1-minute candles: it enters early in a bar when tick flow confirms a
range breakout or a stop-sweep, puts a tight stop on, moves it to break-even, trails it with ATR,
and closes at the candle close. There is no take-profit.

| File | What it is |
|---|---|
| `Experts/ScalpEngine.mq5` | The EA |
| `Scripts/FeedProbe.mq5` | Measures what your broker really sends (order book, trade flags, spread, tick speed) |
| `analyze_trades.py` | Reads the EA's trade log and reports expectancy in R |

## What the EA uses

- **Tick flow:** every tick is pulled with `CopyTicks`, so none are skipped. When the broker
  marks trades as buy or sell, the EA uses those flags. Exness CFDs only send quotes, so the EA falls
  back to the *tick rule*: a quote that moves up counts as buying, one that moves down counts as
  selling. Flow imbalance runs from -1 to +1 over the last `InpFlowWindowSec` seconds.
- **Tick speed:** ticks per second now, compared with the 10-minute average. Breakouts need a burst.
- **Range:** the high and low of the last `InpRangeBars` closed bars.
  - **Breakout:** price is past the range by no more than 0.5 ATR, with flow in the same direction
    and a speed burst.
  - **Sweep fade:** this bar ran past the range, came back inside, and flow flipped.
- **Depth of market:** an imbalance across the top `InpBookLevels` levels. It is used only if the
  broker actually publishes a book. If not, the EA ignores it (the FeedProbe script tells you which).
- **Trend filter:** on M5, a close above or below an EMA, for breakouts only by default.

## Protections

- **Cost gate:** 1m ATR must be at least `InpMinAtrToSpread` times the current spread, and the
  stop must be at least `InpSlMinSpreads` spreads. This is what keeps a 1m scalper from paying all
  its edge in spread.
- **Sizing:** position size from risk % of equity, with a lot cap.
- **Daily loss limit:** stops trading for the server day after an equity drawdown of
  `InpMaxDailyLossPct`. It is measured on account equity, so it counts every position on the
  account.
- **Losing streak:** pauses after N losses in a row.
- **Trade count:** a maximum number of trades per day, and one trade per bar.
- **Sessions:** trading hours in server time. Exness server time is UTC.
- **Trade log:** every closed trade goes to `MQL5/Files/ScalpEngine_<symbol>.csv` with entry
  context, spread, MFE and MAE, and the exit reason.

## Step 1: probe the feed (5 minutes)

1. In MT5, open **File → Open Data Folder**. Copy `Scripts/FeedProbe.mq5` into `MQL5/Scripts/` and
   `Experts/ScalpEngine.mq5` into `MQL5/Experts/`.
2. Open MetaEditor (F4), open both files and press **Compile** (F7). Both must show 0 errors.
3. Open a **BTCUSDm M1** chart (the symbol name depends on your account type) and drag **FeedProbe**
   onto it.
4. Read the **Experts** tab and send me the output. It shows:
   - whether Exness has a real order book for BTC;
   - whether trades carry buy or sell flags;
   - the median spread;
   - the ATR/spread ratio, which tells you how much of an average 1m bar one round trip costs.

## Step 2: backtest on real ticks

In the Strategy Tester (Ctrl+R):

- **Expert:** ScalpEngine. **Symbol:** BTCUSDm. **Timeframe:** M1.
- **Modelling:** **Every tick based on real ticks**. Any other mode is useless for a scalper.
- **Dates:** the last 2–3 months. **Forward:** 1/3. MT5 then keeps the last third out of sample.
- **Deposit and leverage:** the same as your real account.
- **Delays:** test with "Random delay" as well. Exness fills are not instant.

The depth of market does not exist in the tester, so backtests run on tick flow only. The log is
written under the tester agent's folder: `Tester/Agent-*/MQL5/Files/`.

Analyse it with:

```
python mt5/analyze_trades.py path/to/ScalpEngine_BTCUSDm.csv
```

Optimise only a few inputs at a time, for example `InpMinFlowImb`, `InpSlAtr`, `InpTrailStartR`,
`InpRangeBars` and `InpMode`. Keep only settings that also work on the forward third.

## Step 3: demo, then smallest live size

1. Run it on an Exness **demo** account on a VPS. Exness offers a free VPS above a deposit
   threshold; otherwise use any VPS in London or Amsterdam.
2. Leave it for 2–4 weeks and compare the demo log with the backtest: win rate, average R and
   slippage.
3. Go live only if the demo matches. Start with `InpRiskPercent` 0.1–0.25.

## Known limits

- On a CFD feed the "order flow" is inferred from quote changes, not real trades. It is a proxy.
  Real footprint data needs an exchange feed: CME through a futures broker, or Binance or Bybit for
  crypto.
- The EA has not been compiled or run yet. Compile it in MetaEditor and send me any errors.
- Nothing here is profitable until the tester and a demo account say so.

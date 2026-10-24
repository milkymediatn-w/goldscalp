# ScalpEngine v2: candle scalper for MT5 (Exness)

An Expert Advisor that trades one candle at a time. It enters early in a candle when tick flow
confirms one of three setups, puts a tight stop on, moves it to break-even, trails it with ATR,
and closes at the candle close. There is no take-profit.

| File | What it is |
|---|---|
| `Experts/ScalpEngine.mq5` | The EA |
| `Scripts/FeedProbe.mq5` | Measures what your broker really sends (order book, trade flags, spread, tick speed) |
| `analyze_trades.py` | Reads the EA's trade log and reports expectancy in R |

## Why M3 by default

FeedProbe on Exness BTCUSDm (2026-10-23) measured:

- **Spread:** a fixed $6.40.
- **1m ATR:** $18, so one round trip costs about 35% of an average 1m candle.
- **Order book:** none.
- **Trade flags:** none. The feed only sends quotes.

The spread is a fixed cost, but candle size grows with time. On M3 the average candle is roughly
$30, so the spread drops to about 20%. `InpTF` can be set anywhere from M1 to M15.

## Setups

| Setup | Condition |
|---|---|
| `breakout` | Price leaves the high/low of the last `InpRangeBars` candles, by no more than `InpMaxChaseAtr`. Flow must agree, and tick speed must be at least `InpMinTickRateX` times the 10-minute average. |
| `impulse` | The last candle was at least `InpImpulseAtr` times ATR, with a body of at least `InpImpulseBody` of its range. Flow still pushes the same way and price holds that candle's half. |
| `sweep` | This candle ran past the range, came back inside, and flow flipped. Fade it. |

**Flow** is the buy/sell imbalance over the last `InpFlowWindowSec` seconds. On a quote-only feed
it is computed with the *tick rule*: a quote that moves up counts as buying, one that moves down
counts as selling. If the feed has real trade flags, those are used instead.

**Trend filter:** close against an EMA on `InpHtfTF` (default M15 EMA50). It applies to breakout
and impulse; it applies to sweep only if `InpHtfFilterFades` is on.

**Depth of market:** an imbalance is added only when the broker publishes a book. Exness does not
for BTCUSDm.

## Protections

- **Cost gate:** the candle's ATR must be at least `InpMinAtrToSpread` times the spread, and the
  stop must be at least `InpSlMinSpreads` spreads.
- **Regime filters:** skip volatility spikes (ATR(14) above `InpMaxAtrSpikeX` times ATR(100)) and
  slow feeds (below `InpMinTickRate` ticks per second).
- **Sizing:** position size from risk % of equity, with a lot cap.
- **Daily loss limit:** stops trading for the server day after an equity drawdown of
  `InpMaxDailyLossPct`. It is measured on account equity, so it counts every position on the
  account.
- **Losing streak:** pauses after N losses in a row.
- **Trade count:** a maximum number of trades per day, and one trade per bar.
- **Sessions:** trading hours in server time. Exness server time is UTC.
- **Report:** when the EA stops, it prints how many candles each filter skipped, plus entries,
  wins and total R. An on-chart panel shows the live state.
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

- **Expert:** ScalpEngine. **Symbol:** BTCUSDm. **Timeframe:** any. The EA uses `InpTF`, not
  the chart timeframe.
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
`InpRangeBars`, `InpTF` and the three `InpUse*` setup switches. Keep only settings that also work on the forward third.

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
- v1 compiled with 0 errors in MetaEditor; v2 still needs its first compile.
- Nothing here is profitable until the tester and a demo account say so.

---

# MomentumScalper: high-frequency trend + momentum scalper

`Experts/MomentumScalper.mq5`. It checks for entries on **every tick** and holds trades for
seconds to a few minutes. There is one position at a time. There is no martingale, grid or
averaging down.

| Part | How it works |
|---|---|
| **Trend** | The M1 EMA 9 must be above the EMA 21 for longs (below for shorts). An M5 EMA50 filter and a rolling VWAP must agree. Set `InpRequireTrend=false` to trade both ways. |
| **Burst setup** | Price moves at least `InpBurstMinSpreads` spreads in `InpBurstSec` seconds, with one-sided flow (`InpBurstMinFlow`) and tick speed of at least `InpBurstMinSpeedX`. It is skipped if the move is already larger than `InpBurstMaxAtr` ATR. |
| **Pullback setup** | In trend, price dips `InpPbMinAtr`–`InpPbMaxAtr` ATR from the last swing, then breaks the last closed M1 candle's extreme again, with flow agreeing. |
| **Volume profile** | A rolling profile of the last `InpProfileBars` M1 candles' tick volume gives the POC, value area and HVNs. Longs need price above the POC (shorts below), and at least `InpMinRoomR` R of room to the next level. |
| **Exits** | Stop of `InpSlAtr` ATR (at least `InpSlMinSpreads` spreads), TP at `InpTpR` R, break-even at `InpBreakEvenR`, ATR trail from `InpTrailStartR`, a time stop after `InpMaxHoldSec`, and a flow-fade exit when flow turns hard against the trade. |
| **Frequency guards** | `InpCooldownSec` between trades, `InpMaxTradesPerHour`, `InpMaxTradesPerDay`, a losing-streak pause and a daily loss limit. |

The log is written to `MQL5/Files/MomentumScalper_<symbol>.csv`; analyse it with
`analyze_trades.py`. When the EA stops, it prints per-setup results and which filter blocked
trading, minute by minute.

Every trade pays the full spread, so more trades means more cost. On Exness BTCUSDm ($6.40 spread)
a stop of 2.5 spreads means the spread alone is about 0.3R per trade. The setups must win more
than that back on average. The tester decides; nothing here is profitable until it does.

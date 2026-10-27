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

# MomentumScalper v2: momentum + price action + VWAP + SMC scalper

`Experts/MomentumScalper.mq5`. It checks for entries on **every tick** and holds trades for
seconds to a few minutes. There is one position at a time. There is no martingale, grid or
averaging down.

An entry needs **one trigger** plus a **confluence score** of at least `InpMinScore`
(default 55 out of 100). The panel shows the last candidate's score breakdown, so you can always
see why it did or did not trade.

| Trigger | Condition (flow must agree by `InpTrigMinFlow`) |
|---|---|
| `burst` | Price moves at least `InpBurstMinSpreads` spreads in `InpBurstSec` seconds, with tick speed of at least `InpBurstMinSpeedX` |
| `bos` | Price trades through the last unbroken M1 swing high or low (break of structure, or CHoCH if it flips direction) |
| `sweep` | This candle wicks through an unbroken swing (a liquidity grab), then price reclaims it |
| `fvg` | This candle taps the newest unfilled fair value gap and price turns away from it |

| Score item | Points |
|---|---|
| M1 EMA 9/21 trend | 15 |
| M5 EMA50 trend | 10 |
| Correct side of the rolling VWAP | 15 |
| Last structure break in the trade direction | 10 |
| Discount for longs, premium for shorts (60-candle dealing range) | 5 |
| Flow strength | 0–20 |
| Tick speed | 0–10 |
| Correct side of the volume-profile POC | 5 |
| At least `InpRoomR` R of room to the next volume level | 10 |

**Hard gates:**
- M1 ATR must be at least `InpMinAtrToSpread` × spread;
- no volatility spike;
- the feed must not be too slow;
- daily loss limit, trades per hour and per day, cooldown, losing-streak pause.

**Exits:**
- ATR stop of at least `InpSlMinSpreads` spreads. On sweep and FVG trades it sits beyond the wick
  or gap, capped at `InpSlMaxAtr`.
- TP at `InpTpR` R.
- Break-even, then an ATR trail.
- A time stop, and an exit when flow turns hard against the trade.

**Presets** (load them in the Strategy Tester **Inputs** tab: right-click → Load; they cannot be
compiled):
- `Presets/MomentumScalper_HighWinRate.set`: small target, wide stop, early break-even.
- `Presets/MomentumScalper_Optimize.set`: ranges for the genetic optimiser. Use "Custom max" and
  Forward 1/3.

The log goes to `MQL5/Files/MomentumScalper_<symbol>.csv`; analyse it with `analyze_trades.py`.

Every trade pays the full spread, so more trades means more cost. On Exness BTCUSDm ($6.40 spread)
a 3-spread stop means the spread alone is about 0.25R per trade. The tester decides; nothing here
is profitable until it does.

---

# SetupProbe: measure fast-scalp setups before building an EA

`Scripts/SetupProbe.mq5` is a research script. It never trades. It scans M1 history for three
setups, replays the real ticks after each one and measures what a trade held for **at most 10
minutes** would have made after the spread and commission. `analyze_probe.py` slices the result.

| Setup | Signal (on a closed M1 candle) | Trade |
|---|---|---|
| `A_squeeze` | The last `InpSqzBars` candles span at most `InpSqzMaxAtr` × slow ATR, then a candle of at least `InpExpBarAtr` × slow ATR closes outside that range | With the break |
| `B_open` | First close outside the first `InpOrbMin` minutes of a session (`InpSessions`, server time), within `InpOrbWindowMin` minutes | With the break |
| `C_sweep` | The candle wicks at least `InpSweepMinAtr` × ATR through the high/low of the last `InpSweepBars` candles and closes back inside | Fade it |
| `control` | Long and short every `InpControlEvery` candles, no signal | A setup has an edge only if it beats this |

**How a trade is measured:**
- Entry is the first tick after the candle closes plus `InpLatencyMs`, at the ask for longs and
  the bid for shorts. Exits use the other side, so the spread is always paid.
- Every combination of stop (`InpSlAtrList` × ATR, at least `InpSlMinSpreads` spreads) and target
  (`InpTpRList` × the stop) is replayed, plus a time stop at `InpMaxHoldMin` minutes. Stops fill at
  the quote that crossed them (gaps count as slippage); targets fill at their price.
- Results are also recorded for plain time exits after 1, 3, 5 and 10 minutes, with the best and
  worst move in each window.
- Results are reported **gross** (mid to mid) and **net** (after spread and `InpCommission`).
- The last `InpOosFrac` of the period is out of sample. Exit settings are ranked on the in-sample
  part only and then shown with their out-of-sample result.

## Run it

1. Copy `Scripts/SetupProbe.mq5` into `MQL5/Scripts/`, open it in MetaEditor and compile (F7).
2. **Tools → Options → Charts → Max bars in chart: Unlimited.** Open an M1 chart of the symbol and
   scroll back to the start date once, so the terminal downloads the history.
3. Drag **SetupProbe** onto the chart, set `InpFrom` / `InpTo` and, on a Zero or Raw account,
   `InpCommission` (per 1 lot, round trip, from the Exness contract specifications). It replays
   one day of ticks at a time; three months takes a few minutes. Progress shows on the chart.
4. Read the summary in the **Experts** tab, then analyse the event log from `MQL5/Files/`:

```
python mt5/analyze_probe.py SetupProbe_BTCUSDm.csv
python mt5/analyze_probe.py SetupProbe_BTCUSDm.csv --min-ratio 4            # cost gate: ATR >= 4x spread
python mt5/analyze_probe.py SetupProbe_BTCUSDm.csv --hours 7-10,13-16       # active hours only
python mt5/analyze_probe.py SetupProbe_BTCUSD.csv  --commission 7.0         # Zero: commission override
```

Use any filter found this way only if it holds on the OOS columns, and judge nothing with fewer
than ~300 OOS events.

## Compare the account types first

The same setup can lose on one account type and work on another, because a 10-minute scalp
lives or dies on cost. For each account (Standard `BTCUSDm`, Pro, Zero; the symbol name differs
per account type):

1. Run **FeedProbe** on the BTC M1 chart to get the live median spread and the ATR/spread ratio.
2. Run **SetupProbe** on the same dates with that account's commission.
3. Compare the net columns. The cost per round trip is spread + commission; the account with the
   lowest one is the one to build on.

Only setups that are positive net out of sample, on 300+ events, at a realistic cost, go into an EA.

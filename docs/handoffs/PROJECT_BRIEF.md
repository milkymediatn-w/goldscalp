# Project brief: personal algorithmic trading (BTC and gold)

Paste this at the start of a new conversation, or point the session at this file.

## Who and what

- Personal project. My own money, my own account, not for resale or signal selling.
- Broker: **Exness**, MetaTrader 5. Symbols: `BTCUSDm` and `XAUUSDm` (Standard account, "m" suffix).
  Exness MT5 server time is UTC.
- Goal: an automated strategy that is **profitable after costs** in backtests and on a demo account
  before any live money. I care about real results, not a high win rate on paper.
- Data must be **licensed or public**, used within each provider's terms. Paid data later:
  **Databento** (CME gold futures, `GLBX.MDP3`) once I subscribe.

## What already exists

Repository `milkymediatn-w/goldscalp`, branch `claude/busy-brahmagupta-necj0h`, folder `mt5/`:

| File | What it is |
|---|---|
| `Experts/ScalpEngine.mq5` | v2 candle-based EA: enters early in a candle, tight ATR stop, break-even and trailing stop, exits at the candle close. Timeframe is the `InpTF` input (M1–M15). |
| `Experts/MomentumScalper.mq5` | v2.1 tick-level EA: one trigger plus a confluence score. Triggers are burst, BOS/CHoCH, sweep and FVG. The score uses EMA trend, VWAP, structure, flow, tick speed, POC and room to the next level. |
| `Scripts/FeedProbe.mq5` | Reports what the broker feed provides: order book, trade flags, spread, ATR/spread ratio. |
| `analyze_trades.py` | Reads the EAs' CSV trade logs and reports expectancy in R. |
| `btc_live.py` | Live monitor on Coinbase public data (snapshot, volume profile, order-book read). |
| `Presets/*.set` | Strategy Tester presets. They are loaded in the tester's Inputs tab and are never compiled. |

Repository `milkymediatn-w/binance-signal-bot` is a Telegram signal bot (alerts only) running on
Render. Its results are poor and it needs diagnosis from its `/stats` output.

## What the testing proved (Strategy Tester, real ticks, USD, $1,000, 0.01 lot)

**Exness feed (FeedProbe on BTCUSDm):**
- no depth of market;
- no aggressor trade flags; the feed only sends quotes;
- about 1 tick per second.

**Costs:** the BTCUSDm spread is about **$10** in the backtest data and **$6.40** live. The M1 ATR
measured live by FeedProbe was **$18**, so the spread is a large share of any short move.

**MomentumScalper v2.1 on BTCUSDm**, 2026-07-24 → 2026-10-27, backtest plus forward:
- 13,802 trades, profit factor about 0.7, **−$1,064**.
- Before spread it was about **+$180** (+$0.013 per trade), against **$0.10 spread per trade**.
- No trigger, score band, hour of day or trend filter was profitable after costs, in either period.

**MomentumScalper v2.1 on XAUUSDm:** 3,626 trades, profit factor 0.74, win rate 38.6%, **−$901**.

**Earlier versions** (ScalpEngine v1/v2, MomentumScalper v1/v2) also lost money.

**Conclusion:** very short holds (seconds to a few minutes) on Exness CFDs do not cover their costs
with signals built from quotes alone. More parameter tuning would only curve-fit.

## Constraints and standards for the next attempt

1. **Costs first.** Every strategy must model the real spread and commission, and should target
   moves many times the spread. Report results before and after costs.
2. **Validation.**
   - Every tick based on real ticks.
   - Forward 1/3 (out-of-sample).
   - At least 300 trades before judging.
   - Never pick settings from in-sample results alone.
3. **Risk limits in every EA.**
   - One position at a time, or a strictly capped total exposure.
   - A stop on every trade.
   - Daily loss limit, losing-streak pause, max trades per day.
   - Fixed lots or a fixed % risk.
   - No position sizing that grows after losses.
4. **Observability.** A CSV trade log, an end-of-run report of skip reasons, and an on-chart panel.
5. **Demo before live**, then the smallest size.
6. In the Strategy Tester the deposit currency must be **USD, not pips**. With 0.01 lot, the
   average loss on BTCUSDm should read about 0.5, not about 20.

## Licensed / free data available now

- **Exness MT5 history:** tick and bar history for my symbols, through the terminal and the tester.
- **Coinbase Exchange public market-data API:** BTC-USD trades with taker side, order book, and
  candles.
- **Exchange public market-data APIs** (for example Binance, Bybit, OKX) for crypto research,
  within each provider's terms and regional availability.
- **Databento:** $125 sign-up credit for historical CME gold (GC/MGC) data, and live CME data from
  about $33/month non-pro when I subscribe.

## Suggested plan for the new conversation

1. Diagnose the Telegram signal bot from its `/stats` output and backtest, and fix it.
2. Test ScalpEngine v2 at `InpTF` = M15 / H1 on XAUUSDm and BTCUSDm. Fewer trades with larger
   targets make the spread a small part of each trade.
3. Research before building. Use historical data (Exness ticks, public crypto data, Databento
   credit) to measure whether a signal predicts moves **larger than costs** at the intended holding
   time. Build an EA only when it does.
4. When Databento is active: measure whether CME gold order flow leads Exness XAUUSD by more than
   the spread. Build from that result.

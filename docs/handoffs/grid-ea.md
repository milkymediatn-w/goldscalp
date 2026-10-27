# Handoff — MT5 Grid EA (XAUUSD)

## Decisions made
- **Rejected the paid "HFT robot"** (STA support / Xlence). It was a broker-affiliate scheme: signup via their affiliate link, handing over the MT5 password, 1:1000 leverage, deposit bonus, offshore broker with withdrawal complaints.
- **Building my own EAs in MQL5**, running on my Pro MT5 account. The earlier Telegram signal bot failed mainly because of data and latency: delayed yfinance futures data, candle-approximated delta, and signals too slow to scalp.
- **No latency arbitrage.** It breaks broker terms and profits get voided.
- **Dropped low-frequency strategies.** SessionBreakout trades too rarely.
- **Chose the grid/martingale** as the main strategy, aimed at frequent small basket wins.
- **v2:** TP changed from % of balance to points past breakeven; added trailing, fast re-entry, ATR grid step, M15 trend guard, basket time stop, daily limits, commission input.
- **v3:** added an M5 trend alongside M15 (`TREND_FAST_LEADS` default) and a reversal exit, so it follows quick reversals and opens sells.
- Keep each version as a separate file and compare them side by side on demo.

## Test results
- **No backtests run yet.** No Strategy Tester numbers (profit factor, drawdown, hard-stop count) exist.
- **No compile confirmation.** The code was written without access to MetaEditor; compile errors, if any, haven't been reported.
- Demo observations only:
  - v1 held profitable baskets too long. Fixed in v2 (points-based TP).
  - v2 sometimes closes too early. Suspected cause is the trail lock (gives back to 50% of peak).
  - v2 opened mostly buys. Not a bug: the M15 trend has been up. This motivated v3.
- v3 has just been built and is not yet observed.

## What's built
| File | What it is | Status |
|---|---|---|
| `GridMartingale_v3.mq5` | Grid with M5/M15 trend modes, reversal exit | **Main, start testing** |
| `GridMartingale_v2.mq5` | Grid with points TP, trailing, ATR step, M15 guard | Running on demo for comparison |
| `GridMartingale.mq5` | v1 grid | Superseded |
| `SessionBreakout.mq5` | Asian-range breakout | Shelved |
| `TickScalper.mq5` | Tick momentum burst scalper | Shelved |
| `M1MeanReversion.mq5` | M1 Bollinger + RSI fade | Shelved |
| `CLAUDE.md` | Full project context and v3 input reference | Current |

**v3 key defaults:** TP 150 pts past breakeven; trail starts at 80 pts, locks 50%; reversal exit on; hard stop −5% per basket; time stop 240 min; grid step ATR×0.5 (min 150 pts); multiplier 1.3; max 5 levels; re-entry 5 s; spread ≤ 50 pts; new baskets server hours 3–22; daily stop −6%.

## What's still open
1. Compile v3 in MetaEditor and fix any errors.
2. Set `InpCommissionPerLot` to the Pro account's real round-turn commission.
3. Confirm the broker's server-time offset (all hours assume server time).
4. Run v2 and v3 side by side on demo with different magic numbers.
5. Decide whether to loosen the trail (`InpTrailStartPts` → 120, `InpTrailLockPct` → 65) once there's enough demo data.
6. Watch whether M5 fast-leads mode whipsaws in quiet hours. If so, try `TREND_BOTH_AGREE` or an M5 EMA of 20.
7. Backtest 3+ years with real ticks and commission. Judge by profit factor (> 1.3 after costs), hard-stop count versus winning baskets, and max drawdown in trending periods, not by win rate.
8. Not yet decided: BTCUSD settings (needs much wider point values), and when or with what size to go live.

# goldscalp: project context for Claude Code

Personal algorithmic trading for BTC and gold. Own money, own accounts, legal brokers, licensed or
public data only. Not for resale or signal selling. Full source documents are in `docs/handoffs/`:

| File | What it covers |
|---|---|
| `docs/handoffs/PROJECT_BRIEF.md` | The original brief: what was tested, what lost, the rules for the next attempt |
| `docs/handoffs/orderflow-bot.md` | Handoff from a claude.ai chat: Binance order-flow Telegram bot (code now in `orderflow/`) |
| `docs/handoffs/grid-ea.md` | Handoff from a claude.ai chat: grid/martingale EA for XAUUSD (separate codebase) |

## Current focus: order-flow Telegram signals bot (`orderflow/`)

A private signal bot that reads real order flow (Level 2 book, aggressor-side trades, delta,
footprint, volume profile, absorption) to confirm SMC setups (sweeps, FVG, CHoCH), and sends
alerts to ONE private Telegram chat. The user trades the signals manually on MT5.
**Read `orderflow/CLAUDE.md` before working on it**: it holds the hard rules (one chat only, no
API keys, never commit `.env` or `data/`) and the architecture (adapter → events → engine →
notifier).

- Phase 1 (live Binance USD-M `BTCUSDT` data, order-book sync, hourly recording, replay, hourly
  Telegram summary) is built. Offline tests: `cd orderflow && python -m pytest -q` (5 pass).
  **Never run against live Binance yet.** This cloud environment's network policy blocks
  `fapi.binance.com` / `fstream.binance.com`, so the first live run happens on the user's PC or VPS.
- The 2026 split WebSocket endpoints (`/market/stream`, `/public/stream`) come from the earlier
  chat and are unverified here; the first live run confirms them.
- Next: first live run and a few London/New York sessions of recordings, then Phase 2 builders
  (footprint bars, cumulative delta, session volume profile, book imbalance, absorption), then SMC
  detection confirmed by order flow, alert-only mode, and a replay backtest.

## Broker and accounts

- **Exness, MetaTrader 5.** Server time is UTC.
- Standard: `BTCUSDm`, `XAUUSDm`. Pro and Zero: `BTCUSD` (no suffix).
- BTC contract size 1, tick size 0.01, tick value 0.01 USD: 0.01 lot = $0.01 per $1 move.
- Feed on every account: about 1.2 quotes per second, **no depth of market, no trade flags**
  (quotes only).
- Measured round-trip cost for 1 BTC (2026-10-27):

| Account | Cost |
|---|---|
| Standard `BTCUSDm` | $6.40 spread live, about $10 in backtest data |
| Zero `BTCUSD` | 0 spread + about $8.8 commission per lot (derived from demo trades) |
| Pro `BTCUSD` | user reports a spread of 0.01. Unconfirmed: check in the Strategy Tester and with a demo round trip |

## What the testing proved (see the brief for numbers)

MomentumScalper v2.1 and ScalpEngine v1/v2 lost money on BTCUSDm and XAUUSDm. v2.1 earned
+$0.013 per trade before costs against $0.10 spread (0.01 lot). Seconds-to-minutes holds with
quote-only signals do not cover Standard-account costs, and more tuning would only curve-fit.

## MT5 EAs (on hold while the order-flow bot is the focus)

A **fast M1 scalper, every trade closed within 10 minutes**, as an `.mq5` EA on the user's own
terminal, BTC first, on the **Pro** account.

| File | Status |
|---|---|
| `mt5/Experts/FastScalper.mq5` | v1. **Compiles with 0 errors.** Running on an M1 demo chart. No Strategy Tester results yet. |
| `mt5/Scripts/SetupProbe.mq5` | Research script: replays real ticks after each setup and reports net results in and out of sample. Not run yet. |
| `mt5/Scripts/FeedProbe.mq5` | Feed and cost check; takes `InpCommission` for Zero/Raw accounts. |
| `mt5/analyze_probe.py` | Slices the SetupProbe CSV. |
| `mt5/analyze_trades.py` | Reads the EA trade logs (`FastScalper_<symbol>.csv` and older EAs). |
| `mt5/Experts/ScalpEngine.mq5`, `MomentumScalper.mq5` | Older EAs, both lost money. Kept for reference. |
| `orderflow/` | **The new order-flow signals bot (current focus).** See its `CLAUDE.md`. |
| Root: `bot.py`, `strategy.py`, `data.py`, `config.py`, `backtest.py` | Older Telegram signal bot (yfinance / Twelve Data / MT5 feed, candle-approximated delta). Results were poor; replaced by `orderflow/`. |

FastScalper setups (M1 candle close; the same maths as SetupProbe):
- `A_squeeze`: a tight range, then an expansion candle breaks out of it.
- `B_open`: the first break of a session's opening range (00:00, 07:00, 13:30 UTC).
- `C_sweep`: a wick through the N-bar high/low that closes back inside; fade it.

Exits: ATR stop (1 ATR), 1.5R target and a hard 10-minute time stop. Risk: one position, 3% daily
loss limit, 20 trades/day, 60-minute pause after 4 losses, fixed 0.01 lot or fixed %.

### Next steps
1. Strategy Tester on Pro `BTCUSD`, 2026-07-24 → 2026-10-27: real ticks, USD deposit,
   Forward 1/3, one setup at a time, then with Random delay.
2. Read the results (trades, PF, net, backtest vs forward) and the skip report. Keep only setups
   that are positive after costs on the forward third with 300+ trades.
3. Optionally run SetupProbe for the per-setup and per-hour breakdown.
4. Demo for 2–4 weeks, compare with the backtest, then the smallest live size.

## Rules every strategy follows (from the brief)

1. **Costs first.** Model the real spread and commission; report before and after costs.
2. **Validation.** Every tick based on real ticks, Forward 1/3, 300+ trades, never choose settings
   from in-sample results alone.
3. **Risk limits in every EA.** One position or capped exposure, a stop on every trade, daily loss
   limit, losing-streak pause, max trades per day, fixed lots or fixed % risk, **no position sizing
   that grows after losses**.
4. **Observability.** CSV trade log, end-of-run skip report, on-chart panel.
5. **Demo before live**, then the smallest size.
6. Tester deposit currency is **USD, not pips**.

## Open decision: the grid/martingale EA conflicts with rule 3

`docs/handoffs/grid-ea.md` describes `GridMartingale_v1..v3.mq5` (XAUUSD, multiplier 1.3, up to 5
levels, −5% basket hard stop), chosen in a separate chat as the main strategy. A martingale grows
position size after adverse moves, which rule 3 of the brief forbids. It has no backtests and no
compile confirmation. Before any work on it, the user decides which rule set applies. If it goes
ahead, judge it on 3+ years of real ticks by profit factor after costs, hard-stop count and max
drawdown in trending periods, never by win rate.

## Working conventions

- MQL5 is written without MetaEditor in cloud sessions: the user compiles and reports errors.
  A session on the user's Windows PC can copy files into the MT5 data folder and read logs directly.
- Keep each EA version as its own file. Never commit `.env`, credentials or MT5 passwords.
- Never promise profitability; the Strategy Tester and demo decide.

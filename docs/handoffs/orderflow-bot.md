# Handoff Summary — Order-Flow Bot (from claude.ai chat, 2026-10-27)

## Goal
Private signal bot for Sina's own trading only. It reads real order flow
(footprints, cumulative delta, volume/market profile, book imbalance,
absorption) to confirm Smart Money Concepts setups (sweeps, FVG, CHoCH) for
entries and exits. Output: Telegram message to ONE private chat. Sina places
trades manually on MT5 (XAUUSD / BTCUSD). MT5 auto-execution comes later, maybe.

This replaces the old approach (scalp bot using yfinance GC=F candles plus an
*approximated* delta). It is a fresh build, not a retrofit.

## Decisions made
1. **Private use only.** No subscribers, no broadcasting. This keeps any future
   market-data license at cheap non-professional personal-use rates.
   Raw data is never redistributed. Only finished signals leave the bot.
2. **Gold data deferred, BTC first.** Licensed live COMEX gold depth costs
   ~$86–199/mo, so we build and test the whole engine on free BTC data, and
   only pay for gold once the strategy proves itself.
3. **BTC data source: Binance USD-M futures, BTCUSDT perpetual.** Public
   streams, free, no account or API key. Sina has a Binance account, but it is
   NOT used. Do not create API keys.
4. **Architecture: adapter → events → engine → notifier.** Only the adapter
   knows the data provider. Engine stays plain Python so it can move to gold.
5. **Record first, trade later.** Log live sessions, build and backtest the
   strategy on recorded data, run alert-only, and only then trust it.

### Data provider research (for the later gold step)
- Gold futures (GC/MGC) trade on **COMEX**, so only COMEX depth is needed.
- **Databento** CME Globex MDP 3.0 Standard plan: $199/mo (raised from $179 on
  2026-06-22). Exchange license included, Python API, MBO data. Usage-based
  live pricing is discontinued, but historical data is still pay-as-you-go with
  $125 free credits, which is useful for gold backtests.
- **Bookmap Global ($49/mo) + dxFeed COMEX Full Depth ($37/mo) ≈ $86/mo.**
  The data is licensed for use inside Bookmap only. Bookmap's **Python API does
  NOT support dxFeed**, so this route requires a **Java** add-on. Piping raw
  data out of Bookmap to an external bot would break the license.
- **IBKR** (~$11/mo COMEX L2, non-pro): cheapest, but Sina found the account
  application too complicated. Rejected for now.
- **Rithmic via broker:** ~$25 connection + ~$15.50–17 COMEX L2, but some
  brokers add a $100/mo API fee. Still needs a futures account. Rejected.
- **IQFeed:** ~$170+/mo all-in, no cheaper than Databento. Rejected.
- **Massive (formerly Polygon):** $999/mo COMEX. Rejected.
- **Open: gold route not chosen.** Databento = drop-in Python adapter;
  Bookmap/dxFeed = cheaper, but the engine must be ported to Java.

## What's built (Phase 1)
- `adapters/binance_futures.py`: two WebSocket connections, using Binance's
  2026 split endpoints (legacy `/ws` and `/stream` URLs were retired
  2026-04-23; market and public streams cannot share one connection):
  - trades → `wss://fstream.binance.com/market/stream` (`aggTrade`;
    `m=true` means the seller was the aggressor)
  - depth → `wss://fstream.binance.com/public/stream` (`depth@100ms`)
  - Order book sync: buffer diffs, fetch REST snapshot `/fapi/v1/depth`
    (limit 1000), first diff must satisfy `U <= lastUpdateId <= u`, then each
    diff's `pu` must equal the previous `u`. Any gap triggers an automatic
    resync.
  - Auto-reconnect with exponential backoff. Stream up/down/resync events are
    recorded so backtests know where gaps are.
- `core/events.py`: provider-neutral events (Trade, BookSnapshot, BookDiff,
  StreamStatus).
- `core/orderbook.py`: local book with best bid/ask, top-N levels, imbalance.
- `core/recorder.py`: one gzip JSONL file per UTC hour at
  `data/binance-usdm/BTCUSDT/<date>/<HH>.jsonl.gz`. Each file starts with a
  book snapshot, so any hour can be replayed on its own.
- `core/replay.py`: `iter_events()` reads recordings back in time order.
- `core/telegram.py`: sends only to `TELEGRAM_CHAT_ID`.
- `main.py`: startup message, hourly Telegram summary (price range, trades,
  buy/sell volume, delta, spread, top-10 imbalance, reconnects/resyncs).
- `tools/get_chat_id.py`: finds the private chat ID after messaging the bot.
- `CLAUDE.md`, `README.md`, `.env.example`, `.gitignore` (.env and data/ excluded).
- Dependency: `aiohttp` only. Python 3.10+.

## Test results
- **Offline only, with simulated data. All passed:**
  - Snapshot/diff alignment logic, including stale-snapshot detection.
  - Depth loop against a fake WebSocket: snapshot load, diff application,
    level removal at qty 0, and correct resync on a sequence gap.
  - Recorder hourly rotation plus replay round trip (new hour starts with a
    snapshot; all events read back).
  - All files compile.
- **NOT yet tested against live Binance.** The chat environment couldn't reach
  Binance. The first real run is the first live test.

## Still open
1. First live run: fill in `.env` (Telegram token + chat ID), run `main.py`,
   confirm the online message, the hourly summary, and recording files.
2. Check disk usage at `DEPTH_SPEED=100ms` (expected: a few hundred MB/day).
   Switch to 500ms if needed.
3. Run on Sina's PC or a VPS with persistent disk. Not Render (disk is wiped
   on restart).
4. Let it record several London and New York sessions.
5. **Phase 2:** builders that work on both live and replayed events —
   footprint bars, cumulative delta, session volume profile (POC/VAH/VAL),
   book imbalance, absorption, pulled/stacked liquidity.
6. **Phase 3:** SMC setup detection confirmed by order flow, alert-only mode
   to Telegram, replay backtest.
7. **Later:** choose gold data route (Databento vs Bookmap/dxFeed); handle
   COMEX contract rolls; translate GC levels to MT5 XAUUSD using the live
   GC-vs-spot basis; optional MT5 execution bridge (Windows VPS, since the
   MetaTrader5 Python package is Windows-only).

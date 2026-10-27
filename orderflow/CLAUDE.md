# Order-Flow Bot — project context

## Goal
A PRIVATE trading-signal bot for the owner only. It reads real order flow
(footprints, cumulative delta, volume/market profile, order-book imbalance,
absorption) and uses it to confirm Smart Money Concepts setups (liquidity
sweeps, FVGs, CHoCH) for entries and exits. Output = Telegram message to ONE
private chat ID. The owner places trades manually on MT5 (XAUUSD / BTCUSD CFDs).

## Hard rules
- Signals go only to TELEGRAM_CHAT_ID from .env. Never add multi-user
  broadcasting: market-data licenses used later for gold are non-professional,
  personal-use only.
- No exchange API keys. Binance data used here is public; no account access.
- Never commit .env or data/.

## Current state (Phase 1 — done)
- adapters/binance_futures.py: Binance USD-M futures BTCUSDT.
  Uses the 2026 split WebSocket endpoints (legacy /ws and /stream URLs were
  retired 2026-04-23):
    trades -> wss://fstream.binance.com/market/stream (aggTrade)
    depth  -> wss://fstream.binance.com/public/stream (depth@100ms)
  Market and public streams cannot share a connection.
  Book sync: buffer diffs, REST snapshot /fapi/v1/depth, first diff must
  satisfy U <= lastUpdateId <= u, then each diff's pu == previous u, else resync.
  aggTrade m=True means the SELLER was the aggressor.
- core/events.py: provider-neutral events (Trade, BookSnapshot, BookDiff,
  StreamStatus). The engine must only ever consume these.
- core/recorder.py: hourly gzip JSONL in data/<source>/<SYMBOL>/<date>/<HH>.jsonl.gz,
  each hour starts with a book snapshot. core/replay.py reads them back.
- main.py: wiring, hourly Telegram summary.
- Verified offline with simulated data only (tests/test_phase1.py); first live run is the real test.

## Architecture principle
adapter -> events -> engine -> notifier. Only the adapter knows the data
provider. Keep engine code plain Python with no provider/platform dependencies
so it can move to gold data later.

## Gold upgrade path (later, undecided)
- Databento CME Globex MDP 3.0 (~$199/mo): Python, just add a new adapter.
- Bookmap Global + dxFeed COMEX depth (~$86/mo): data is licensed for use
  inside Bookmap only, and Bookmap's Python API does NOT support dxFeed, so
  the engine would have to run as a Java add-on. Raw data must not be piped
  out of Bookmap; only finished signals may leave.
- Gold futures (GC/MGC) trade on COMEX. Signals must be translated to the
  owner's MT5 XAUUSD price via the live GC-vs-spot basis.

## Next (Phase 2)
Builders that run on live events AND on replayed recordings:
footprint bars (bid/ask volume per price), cumulative delta, session volume
profile (POC/VAH/VAL), book imbalance / absorption / pulled-stacked liquidity.
Then: SMC setup detection confirmed by order flow, alert-only mode to Telegram,
and a replay backtest before any live use.

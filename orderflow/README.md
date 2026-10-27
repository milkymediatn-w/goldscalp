# Order-Flow Bot — Phase 1 (live data + recorder + Telegram)

Connects to Binance USDⓈ-M futures **BTCUSDT** public data (no account, no API key),
rebuilds the live order book, records every trade and book update to disk,
and sends you a private Telegram summary every hour.

## Setup (Windows or Linux, Python 3.10+)

```
pip install -r requirements.txt
copy .env.example .env        (Linux/Mac: cp .env.example .env)
```

**Telegram (private to you):**
1. In Telegram, message **@BotFather** → `/newbot` → copy the token into `.env` as `TELEGRAM_BOT_TOKEN`.
2. Open your new bot and send it any message.
3. Run `python tools/get_chat_id.py` and put the number into `.env` as `TELEGRAM_CHAT_ID`.

Only that chat ID ever receives messages.

## Run

```
python main.py
```

You should get "✅ Order-flow bot online" on Telegram, then a summary each hour
(price range, trades, buy/sell volume, delta, spread, book imbalance, connection health).
Stop with Ctrl+C.

## Tests (offline, no network)

```
pip install pytest
python -m pytest -q
```

They cover the order book, snapshot/diff alignment, depth resync on a sequence gap, trade side
mapping, and hourly recording with replay.

## Recorded data

`data/binance-usdm/BTCUSDT/<date>/<hour>.jsonl.gz` — one compressed file per UTC hour,
each starting with a full book snapshot. Expect roughly a few hundred MB per day at
`DEPTH_SPEED=100ms`; use `500ms` to cut that down.
Read it back with `core/replay.py` → `iter_events(...)` for backtesting.

Run it on your own PC or a VPS with a persistent disk — not Render, whose disk is wiped on restart.

## Layout

```
adapters/binance_futures.py   data source (swap/add a gold adapter later)
core/events.py                provider-neutral events: Trade, BookSnapshot, BookDiff, StreamStatus
core/orderbook.py             local order book
core/recorder.py / replay.py  save + reload sessions
core/telegram.py              private notifier
main.py                       wiring + hourly summary
```

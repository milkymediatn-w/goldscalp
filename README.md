# GoldScalp Signals Bot

## Quick start
1. Create a bot with @BotFather and copy the token.
2. `cp .env.example .env`, fill it in (get your numeric ID from @userinfobot for ADMIN_IDS).
3. `pip install -r requirements.txt`
4. `python backtest.py` to sanity-check the strategy on your data.
5. `python bot.py`

## Files
- `config.py`   presets + every tunable input (override any field from .env)
- `data.py`     OANDA (gold spot) / Coinbase (BTC) / yfinance fallback feeds
- `strategy.py` indicators, confluence scoring, TP1/2/3 trade simulation
- `bot.py`      Telegram UI, subscriptions, scanner, outcome tracking
- `backtest.py` runs the exact live logic over history
- `apifinder.py` searches the public-apis catalogue for new data sources (`python apifinder.py --preset gold`); shortlist in `DATA_SOURCES.md`

## Gold data feed (OANDA, default)
- Open a free OANDA **practice** account, then My Account -> Manage API Access -> Generate token.
- Set `DATA_SOURCE=oanda`, `OANDA_TOKEN=<token>`, `OANDA_ENV=practice` (use `live` only with a live-account token).
- You get spot XAU/USD candles plus the live bid/ask spread. One request per scan is far below OANDA's rate limits.
- `DATA_SOURCE=yfinance` falls back to `GC=F` gold **futures**, which trade a few dollars away from spot.

## Using your MT5 account as the data feed
- MT5's Python API is **Windows only** and talks to a desktop terminal. Install MT5 from your broker on the
  same Windows PC/VPS that runs the bot, log in once. Algo Trading does not need to be enabled (data only).
- Set `DATA_SOURCE=mt5`, `MT5_LOGIN`, `MT5_SERVER`, and your broker's exact gold symbol in `MT5_SYMBOL`
  (check Market Watch: XAUUSD, XAUUSDm, GOLD, XAUUSD.r...).
- **Use the INVESTOR (read-only) password** for `MT5_PASSWORD`. The bot only reads candles and the live
  spread, it never places orders, so it never needs the trading password. If you leave login blank it
  attaches to whatever account the open terminal is logged into.
- Keep `.env` private (never commit it). Anyone with the file has your login.
- Broker server time is auto-detected and converted to UTC. If session filters look off, set `MT5_UTC_OFFSET`.
- The bot skips signals when the live spread is above `MAX_SPREAD`, and tracked results are net of the real spread.

## Admin commands
/grant <id> <days>, /revoke <id>, /admin, /status, /broadcast <text>

Forward-test for several weeks before charging anyone. The Performance screen logs every signal.

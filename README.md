# GoldScalp Signals Bot

## Quick start
1. Create a bot with @BotFather and copy the token.
2. `cp .env.example .env`, fill it in (get your numeric ID from @userinfobot for ADMIN_IDS).
3. `pip install -r requirements.txt`
4. `python backtest.py` to sanity-check the strategy on your data.
5. `python bot.py`

## Files
- `config.py`   presets + every tunable input (override any field from .env)
- `data.py`     MT5 / Twelve Data / yfinance feeds
- `strategy.py` indicators, confluence scoring, TP1/2/3 trade simulation
- `bot.py`      Telegram UI, subscriptions, scanner, outcome tracking
- `backtest.py` runs the exact live logic over history

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

# Data source candidates

Shortlist pulled from the [public-apis](https://github.com/public-apis/public-apis) catalogue with
`python apifinder.py --preset gold` (also `--preset macro`, `--preset crypto`). Descriptions come from
the catalogue. None of these are wired into `data.py` yet. Check each one's free-tier limits, candle
granularity and latency before relying on it.

Current feeds: MT5 (broker), yfinance `GC=F` (gold **futures**, not spot), Coinbase spot (BTC).

## Gold price (XAUUSD)
| API | Key | Why it's interesting |
|---|---|---|
| [Goldprice.dev](https://goldprice.dev/docs) | none | Gold/silver/copper spot **and** futures, 30-year history. Could provide spot to sanity-check the `GC=F` futures basis. |
| [Finage](https://finage.co.uk) | apiKey | Forex, indices and crypto, real-time and historical. |
| [TickerLayer](https://tickerlayer.com) | apiKey | Stocks, forex and crypto, real-time and historical. |
| [Finnhub](https://finnhub.io/docs/api) | apiKey | REST plus a **websocket** for forex/crypto, which suits tick-level spread checks. |
| [Alpha Vantage](https://www.alphavantage.co/) | apiKey | FX intraday. The free tier is heavily rate-limited. |
| [IG](https://labs.ig.com/gettingstarted) | apiKey | CFD/spreadbet market data, so you see broker-style spot gold quotes and spreads. |
| [KmalServico](https://www.kmalservico.com/data) | none | Per-gram retail prices only. Not useful for scalping. |

## Context and filters (sessions, macro, sentiment)
| API | Key | Use |
|---|---|---|
| [Futures Clock](https://futuresclock.com/en/data-methodology/#open-data) | none | Trading hours and session windows for 65 futures products. Could drive the session filter. |
| [FRED](https://fred.stlouisfed.org/docs/api/fred/) | apiKey (free) | Real yields, DXY proxies and CPI, the main macro drivers of gold. |
| [Fed Treasury](https://fiscaldata.treasury.gov/api-documentation/) | none | Treasury rates and auctions. |
| [Helious](https://helious.io/developers/) | none | Treasury auction results plus scored economic releases. Useful for news-time blackout windows. |
| [FXNewsBias](https://fxnewsbias.com/developers) | apiKey | News sentiment for USD and the other major currencies, refreshed every 3 hours. |
| [Frankfurter](https://frankfurter.dev) | none | Daily FX reference rates (ECB). Lets us build a cheap USD-strength index. |

## BTC
Coinbase spot is already in place. To cross-check it, run `python apifinder.py --preset crypto --no-auth`.

"""
GoldScalp Signals Bot - Autonomous Cloud Version (Render + Twelve Data)
Runs FastAPI health-check server + Telegram Bot + Background Scanner.
"""
import asyncio
import json
import logging
import os
import sqlite3
from contextlib import closing
from datetime import datetime, timedelta, timezone
from threading import Thread

import pandas as pd
from dotenv import load_dotenv
from fastapi import FastAPI
import uvicorn
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.error import BadRequest, Forbidden, TelegramError
from telegram.ext import Application, CallbackQueryHandler, CommandHandler, ContextTypes

load_dotenv()

from config import load_config
from data import get_candles
from strategy import evaluate, simulate

CFG = load_config()
BOT_TOKEN = os.environ["BOT_TOKEN"]
ADMIN_IDS = {int(x) for x in os.getenv("ADMIN_IDS", "").split(",") if x.strip()}
SCAN_SECONDS = int(os.getenv("SCAN_SECONDS", "30"))
DB_PATH = os.getenv("DB_PATH", "signals_v2.db")
BRAND = os.getenv("BRAND_NAME", "GoldScalp Signals")
SUPPORT = os.getenv("SUPPORT_HANDLE", "@your_support")
PRICE_TEXT = os.getenv("PRICE_TEXT", "$29 / month")
DEFAULT_USER_SCORE = int(os.getenv("DEFAULT_USER_SCORE", "40"))
FREE_DELAY_MIN = int(os.getenv("FREE_DELAY_MIN", "0"))
TF = {1: "M1", 5: "M5", 15: "M15", 60: "H1"}.get(CFG.tf_min, f"{CFG.tf_min}m")

logging.basicConfig(format="%(asctime)s %(levelname)s %(message)s", level=logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("goldbot")
STATE = {"last_scan": None, "last_bar": None, "error": None, "alerted": False, "spread": None, "source": None}

# --- FastAPI Web Server (Required for Render Free Web Service) ---
app = FastAPI(title="GoldScalp Bot Health")

@app.get("/")
def health_check():
    return {
        "status": "online",
        "brand": BRAND,
        "preset": CFG.preset,
        "source": STATE["source"],
        "last_scan": STATE["last_scan"],
        "last_bar": STATE["last_bar"],
        "error": STATE["error"]
    }

def run_web():
    port = int(os.environ.get("PORT", 10000))
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="warning")


# --- Database & Telegram Code ---
def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def q(sql, args=(), one=False, commit=False):
    with closing(db()) as c:
        cur = c.execute(sql, args)
        if commit:
            c.commit()
            return cur.lastrowid
        return cur.fetchone() if one else cur.fetchall()

def init_db():
    with closing(db()) as c:
        c.executescript(
            """
            CREATE TABLE IF NOT EXISTS users(
                user_id INTEGER PRIMARY KEY, username TEXT, joined TEXT,
                premium_until TEXT, min_score INTEGER DEFAULT 40, alerts INTEGER DEFAULT 1
            );
            CREATE TABLE IF NOT EXISTS signals(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts TEXT, created TEXT, side TEXT,
                entry REAL, sl REAL, tp1 REAL, tp2 REAL, tp3 REAL,
                score INTEGER, atr REAL, spread REAL, reasons TEXT,
                status TEXT DEFAULT 'OPEN', stage INTEGER DEFAULT 0,
                closed_ts TEXT, r REAL
            );
            """
        )
        c.commit()

def now_utc() -> datetime:
    return datetime.now(timezone.utc)

def register(user):
    q("INSERT OR IGNORE INTO users(user_id, username, joined, min_score) VALUES(?,?,?,?)",
      (user.id, user.username or "", now_utc().isoformat(), DEFAULT_USER_SCORE), commit=True)

def premium_until(uid: int):
    row = q("SELECT premium_until FROM users WHERE user_id=?", (uid,), one=True)
    return datetime.fromisoformat(row["premium_until"]) if row and row["premium_until"] else None

def is_premium(uid: int) -> bool:
    if uid in ADMIN_IDS:
        return True
    until = premium_until(uid)
    return bool(until and until > now_utc())

def track_open(df: pd.DataFrame) -> list:
    out = []
    for r in q("SELECT * FROM signals WHERE status='OPEN'"):
        ts = pd.Timestamp(r["ts"])
        if df.index[0] > ts:
            q("UPDATE signals SET status='EXPIRED', closed_ts=?, r=0 WHERE id=?",
              (now_utc().isoformat(), r["id"]), commit=True)
            continue
        res = simulate(dict(r), df[df.index > ts], CFG)
        risk = abs(r["entry"] - r["sl"])
        spread = r["spread"] if r["spread"] is not None else CFG.assumed_spread
        net = round(res["r"] - spread / risk, 2) if res["status"] != "OPEN" and risk else None

        events = [k for k in res["events"] if k.startswith("TP") and int(k[2]) > r["stage"]]
        if res["status"] in ("SL", "BE", "EXPIRED"):
            events.append(res["status"])

        if res["status"] != "OPEN":
            q("UPDATE signals SET status=?, stage=?, closed_ts=?, r=? WHERE id=?",
              (res["status"], res["stage"], now_utc().isoformat(), net, r["id"]), commit=True)
        elif res["stage"] != r["stage"]:
            q("UPDATE signals SET stage=? WHERE id=?", (res["stage"], r["id"]), commit=True)
        out.extend((r, k, net) for k in events)
    return out

def _rmult(r, key) -> float:
    risk = abs(r["entry"] - r["sl"])
    return abs(r[key] - r["entry"]) / risk if risk else 0

def fmt_signal(r) -> str:
    icon = "🟢" if r["side"] == "BUY" else "🔴"
    reasons = "\n".join(f"• {x}" for x in json.loads(r["reasons"]))
    be = "Move stop to entry after TP1." if CFG.be_after_tp1 else "Keep the original stop."
    return (
        f"{icon} <b>{r['side']} XAUUSD</b>  |  {TF}\n\n"
        f"📍 Entry: <code>{r['entry']:.2f}</code>\n"
        f"🛑 Stop Loss: <code>{r['sl']:.2f}</code>\n"
        f"🎯 TP1: <code>{r['tp1']:.2f}</code>  ({_rmult(r, 'tp1'):.1f}R)\n"
        f"🎯 TP2: <code>{r['tp2']:.2f}</code>  ({_rmult(r, 'tp2'):.1f}R)\n"
        f"🎯 TP3: <code>{r['tp3']:.2f}</code>  ({_rmult(r, 'tp3'):.1f}R)\n"
        f"⭐ Confidence: <b>{r['score']}/100</b>\n\n"
        f"<b>Why:</b>\n{reasons}\n\n"
        f"<b>Plan:</b> close 1/3 at each target. {be}"
    )

def fmt_event(r, kind: str, net) -> str:
    head = f"<b>{r['side']} XAUUSD #{r['id']}</b>"
    be = "\nMove your stop to entry." if CFG.be_after_tp1 else ""
    return {
        "TP1": f"✅ {head}: TP1 hit. Bank 1/3.{be}",
        "TP2": f"✅ {head}: TP2 hit. Bank another 1/3.",
        "TP3": f"🏆 {head}: TP3 hit. Complete.\nResult: <b>{net:+.2f}R</b>" if net is not None else "",
        "SL": f"❌ {head}: Stop loss hit.\nResult: <b>{net:+.2f}R</b>" if net is not None else "",
        "BE": f"➖ {head}: Stopped at break-even.\nResult: <b>{net:+.2f}R</b>" if net is not None else "",
        "EXPIRED": f"⏱ {head}: Expired.\nResult: <b>{net:+.2f}R</b>" if net is not None else "",
    }[kind]

def fmt_performance() -> str:
    rows = q("SELECT * FROM signals WHERE status!='OPEN' ORDER BY id ASC")
    if not rows:
        return "📊 <b>Performance</b>\n\nNo closed signals yet."
    rs = [r["r"] or 0.0 for r in rows]
    n, wins = len(rs), [x for x in rs if x > 0]
    gross_loss = -sum(x for x in rs if x < 0)
    pf = f"{sum(wins) / gross_loss:.2f}" if gross_loss > 0 else "∞"
    return (
        "📊 <b>Verified Performance</b>\n\n"
        f"Closed signals: <b>{n}</b>\n"
        f"Win rate: <b>{len(wins) / n * 100:.0f}%</b>   Profit factor: <b>{pf}</b>\n"
        f"Total: <b>{sum(rs):+.1f}R</b>"
    )

def main_kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("📡 Latest Signal", callback_data="signal"),
         InlineKeyboardButton("📊 Performance", callback_data="perf")],
        [InlineKeyboardButton("⚙️ Settings", callback_data="settings"),
         InlineKeyboardButton("💎 Premium", callback_data="premium")],
        [InlineKeyboardButton("⚠️ Disclaimer", callback_data="disc")],
    ])

def back_kb(extra=None) -> InlineKeyboardMarkup:
    rows = [extra] if extra else []
    rows.append([InlineKeyboardButton("⬅️ Menu", callback_data="home")])
    return InlineKeyboardMarkup(rows)

def home_text(uid: int) -> str:
    tier = "💎 Premium" if is_premium(uid) else "🆓 Free"
    return f"🥇 <b>{BRAND}</b>\n\nXAUUSD signals on {TF}.\nYour plan: {tier}\n\nChoose an option:"

def settings_view(uid: int):
    u = q("SELECT alerts, min_score FROM users WHERE user_id=?", (uid,), one=True)
    row = [InlineKeyboardButton(("✅ " if u["min_score"] == s else "") + str(s), callback_data=f"score:{s}")
           for s in (40, 50, 60, 70)]
    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton(f"🔔 Alerts: {'ON' if u['alerts'] else 'OFF'}", callback_data="alerts")],
        row,
        [InlineKeyboardButton("⬅️ Menu", callback_data="home")],
    ])
    text = f"⚙️ <b>Settings</b>\n\nAlerts: <b>{'ON' if u['alerts'] else 'OFF'}</b>\nMin Score: <b>{u['min_score']}</b>"
    return text, kb

def signal_view(uid: int) -> str:
    rows = q("SELECT * FROM signals ORDER BY id DESC LIMIT 20")
    if not rows:
        return "📡 <b>Latest Signal</b>\n\nNo signal available right now."
    r = rows[0]
    status = r["status"] if r["status"] != "OPEN" else (f"OPEN (TP{r['stage']} hit)" if r["stage"] else "OPEN")
    return fmt_signal(r) + f"\n\nStatus: <b>{status}</b>"

def premium_text(uid: int) -> str:
    until = premium_until(uid)
    status = f"✅ Active until {until:%Y-%m-%d}" if is_premium(uid) else "Not active"
    return f"💎 <b>Premium</b>   {PRICE_TEXT}\n\nStatus: <b>{status}</b>\n\nMessage {SUPPORT} with ID: <code>{uid}</code>"

async def start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    register(update.effective_user)
    await update.message.reply_text(home_text(update.effective_user.id),
                                    parse_mode=ParseMode.HTML, reply_markup=main_kb())

async def on_button(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    cb = update.callback_query
    await cb.answer()
    uid, data = cb.from_user.id, cb.data
    register(cb.from_user)
    kb = back_kb()

    if data == "home":
        text, kb = home_text(uid), main_kb()
    elif data == "signal":
        text = signal_view(uid)
        kb = back_kb([InlineKeyboardButton("🔄 Refresh", callback_data="signal")])
    elif data == "perf":
        text = fmt_performance()
    elif data == "disc":
        text = "⚠️ Signals are for educational purposes only."
    elif data == "premium":
        text = premium_text(uid)
    elif data == "settings":
        text, kb = settings_view(uid)
    elif data == "alerts":
        q("UPDATE users SET alerts = 1 - alerts WHERE user_id=?", (uid,), commit=True)
        text, kb = settings_view(uid)
    elif data.startswith("score:"):
        q("UPDATE users SET min_score=? WHERE user_id=?", (int(data.split(":")[1]), uid), commit=True)
        text, kb = settings_view(uid)
    else:
        return
    try:
        await cb.edit_message_text(text, parse_mode=ParseMode.HTML, reply_markup=kb)
    except BadRequest:
        pass

async def push(bot, text: str, min_score: int):
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("📊 Performance", callback_data="perf"),
                                InlineKeyboardButton("⬅️ Menu", callback_data="home")]])
    for u in q("SELECT user_id FROM users WHERE alerts=1 AND min_score<=?", (min_score,)):
        try:
            await bot.send_message(u["user_id"], text, parse_mode=ParseMode.HTML, reply_markup=kb)
        except TelegramError:
            pass
        await asyncio.sleep(0.05)

async def scan(ctx: ContextTypes.DEFAULT_TYPE):
    try:
        feed = await asyncio.to_thread(get_candles, CFG)
    except Exception as e:
        log.warning("data error: %s", e)
        STATE["error"] = str(e)
        return
    df = feed.df
    STATE.update(last_scan=now_utc().strftime("%H:%M:%S UTC"), last_bar=str(df.index[-1]),
                 error=None, spread=feed.spread, source=feed.source)

    for r, kind, net in track_open(df):
        text = fmt_event(r, kind, net)
        if text:
            await push(ctx.bot, text, r["score"])

    if q("SELECT 1 FROM signals WHERE status='OPEN'", one=True):
        return
    sig = evaluate(df, CFG)
    if not sig:
        return

    sid = q(
        "INSERT INTO signals(ts, created, side, entry, sl, tp1, tp2, tp3, score, atr, spread, reasons) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
        (sig.ts.isoformat(), now_utc().isoformat(), sig.side, sig.entry, sig.sl, sig.tp1, sig.tp2, sig.tp3,
         sig.score, sig.atr, feed.spread or CFG.assumed_spread, json.dumps(sig.reasons)), commit=True)
    log.info("New signal #%s %s @ %.2f (score %d)", sid, sig.side, sig.entry, sig.score)
    await push(ctx.bot, fmt_signal(q("SELECT * FROM signals WHERE id=?", (sid,), one=True)), sig.score)

def main():
    init_db()
    
    # Start FastAPI health server in a separate background thread
    t = Thread(target=run_web, daemon=True)
    t.start()
    log.info("FastAPI health-check server started in background thread.")

    # Start Telegram Bot application
    app_tg = Application.builder().token(BOT_TOKEN).build()
    app_tg.add_handler(CommandHandler(["start", "menu"], start))
    app_tg.add_handler(CallbackQueryHandler(on_button))
    app_tg.job_queue.run_repeating(scan, interval=SCAN_SECONDS, first=5)
    
    log.info("%s started | %s", BRAND, CFG.summary())
    app_tg.run_polling()

if __name__ == "__main__":
    main()
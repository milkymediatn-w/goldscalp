"""
Main Telegram Bot & FastAPI orchestrator for 24/7 multi-asset scalping on Render.
Handles user subscriptions, background scanning loops, and instant alert broadcasting.
"""
import logging
import os
import sqlite3
import threading
from fastapi import FastAPI
import uvicorn
from telegram import Update
from telegram.ext import ApplicationBuilder, CommandHandler, ContextTypes

from config import Config
from data import get_candles
from strategy import evaluate_strategy

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(message)s", level=logging.INFO
)
logger = logging.getLogger(__name__)

# Database setup for Telegram user subscriptions
DB_FILE = "users.db"


def init_db():
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute(
        "CREATE TABLE IF NOT EXISTS users (chat_id INTEGER PRIMARY KEY)"
    )
    conn.commit()
    conn.close()


def add_user(chat_id: int):
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute("INSERT OR IGNORE INTO users (chat_id) VALUES (?)", (chat_id,))
    conn.commit()
    conn.close()


def get_all_users():
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute("SELECT chat_id FROM users")
    rows = c.fetchall()
    conn.close()
    return [row[0] for row in rows]


# FastAPI health-check server for Render
app = FastAPI()


@app.get("/")
def root():
    return {"status": "online", "service": "Gold & Crypto Scalp Bot"}


@app.get("/health")
def health():
    return {"status": "healthy"}


def run_fastapi():
    port = int(os.getenv("PORT", 10000))
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="warning")


# Tracking last signaled state to prevent duplicate spamming
last_signals = {}


async def scan_market(context: ContextTypes.DEFAULT_TYPE):
    cfg = Config()
    symbols = ["XAUUSD", "BTCUSD"]

    for symbol in symbols:
        try:
            feed = get_candles(cfg, symbol)
            res = evaluate_strategy(feed.df)

            if res.action and res.score >= 40:
                signal_key = f"{symbol}_{res.action}"
                current_candle_time = feed.df.index[-1].timestamp()
                last_time = last_signals.get(signal_key, 0)

                # Send alert only on new candle signals
                if current_candle_time > last_time:
                    last_signals[signal_key] = current_candle_time

                    msg = (
                        f"🚨 **{symbol} {res.action} SIGNAL** 🚨\n"
                        f"• **Price**: `${res.entry:,.2f}`\n"
                        f"• **Score**: `{res.score}/100` (Source: `{feed.source}`)\n"
                        f"• **Stop Loss**: `${res.sl:,.2f}`\n"
                        f"• **Take Profit**: `${res.tp:,.2f}`\n\n"
                        f"**Institutional Confluences**:\n"
                    )
                    for note in res.details.get("notes", []):
                        msg += f"  - {note}\n"

                    msg += (
                        f"\n• **POC**: `${res.details.get('poc', 0):,.2f}`\n"
                        f"• **Value Area**: `${res.details.get('val', 0):,.2f}` - `${res.details.get('vah', 0):,.2f}`"
                    )

                    users = get_all_users()
                    for chat_id in users:
                        try:
                            await context.bot.send_message(
                                chat_id=chat_id, text=msg, parse_mode="Markdown"
                            )
                        except Exception as e:
                            logger.error(f"Failed to send alert to {chat_id}: {e}")

                    logger.info(
                        f"New {symbol} signal #{res.action} @ {res.entry} (score {res.score}) sent to {len(users)} users."
                    )
        except Exception as e:
            logger.error(f"Error scanning {symbol}: {e}")


async def start_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    add_user(chat_id)
    await update.message.reply_text(
        "🤖 **Gold & Crypto Scalping Bot Activated!**\n\n"
        "You are now registered to receive institutional SMC and Volume Profile scalp signals for XAUUSD and BTCUSD."
    )


def main():
    init_db()
    token = os.getenv("BOT_TOKEN")
    if not token:
        raise ValueError("BOT_TOKEN environment variable is missing!")

    # Start FastAPI in background thread for Render health checks
    threading.Thread(target=run_fastapi, daemon=True).start()
    logger.info("FastAPI health-check server started in background thread.")

    # Build Telegram application with pending updates dropped
    application = ApplicationBuilder().token(token).build()
    application.add_handler(CommandHandler("start", start_command))

    # Register interval scan job (every 30 seconds)
    job_queue = application.job_queue
    if job_queue:
        job_queue.run_repeating(scan_market, interval=30, first=5)
        logger.info("Added interval scan job (every 30s).")

    logger.info("Bot starting polling...")
    application.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        logger.critical(f"Fatal startup error: {e}", exc_info=True)
        raise
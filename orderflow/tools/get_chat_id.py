"""Find your private chat ID.
1. Create a bot with @BotFather and put TELEGRAM_BOT_TOKEN in .env
2. Open your bot in Telegram and send it any message (e.g. "hi")
3. Run:  python tools/get_chat_id.py
"""
import json
import os
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config  # noqa: E402,F401  (loads .env)

token = os.getenv("TELEGRAM_BOT_TOKEN", "")
if not token:
    sys.exit("Set TELEGRAM_BOT_TOKEN in .env first.")

with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/getUpdates", timeout=15) as r:
    data = json.load(r)

chats = {}
for upd in data.get("result", []):
    msg = upd.get("message") or upd.get("edited_message") or {}
    chat = msg.get("chat")
    if chat:
        chats[chat["id"]] = chat.get("username") or chat.get("first_name") or chat.get("title")

if not chats:
    print("No messages found. Send your bot a message in Telegram, then run this again.")
for cid, name in chats.items():
    print(f"chat_id={cid}  ({name})  -> put this in .env as TELEGRAM_CHAT_ID")

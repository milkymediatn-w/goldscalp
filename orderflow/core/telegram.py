"""Sends messages to ONE private Telegram chat (yours) and nowhere else."""
import logging

import aiohttp

log = logging.getLogger("telegram")


class TelegramNotifier:
    def __init__(self, token: str, chat_id: str, session: aiohttp.ClientSession):
        self.token = token
        self.chat_id = chat_id
        self.session = session
        if not (token and chat_id):
            log.warning("Telegram not configured; messages will only be logged")

    async def send(self, text: str) -> bool:
        if not (self.token and self.chat_id):
            log.info("[telegram disabled] %s", text)
            return False
        url = f"https://api.telegram.org/bot{self.token}/sendMessage"
        payload = {"chat_id": self.chat_id, "text": text, "parse_mode": "HTML",
                   "disable_web_page_preview": True}
        try:
            async with self.session.post(url, json=payload) as r:
                if r.status != 200:
                    log.error("Telegram error %s: %s", r.status, await r.text())
                    return False
            return True
        except aiohttp.ClientError as exc:
            log.error("Telegram send failed: %s", exc)
            return False

"""Settings, read from environment variables or a local .env file."""
import os
from dataclasses import dataclass, field
from pathlib import Path


def _load_dotenv(path: str = ".env") -> None:
    p = Path(path)
    if not p.exists():
        return
    for line in p.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_dotenv()


@dataclass(frozen=True)
class Config:
    symbol: str = field(default_factory=lambda: os.getenv("SYMBOL", "BTCUSDT").upper())
    # Binance futures diff-depth speeds: 100ms, 250ms (default stream), 500ms
    depth_speed: str = field(default_factory=lambda: os.getenv("DEPTH_SPEED", "100ms"))
    data_dir: Path = field(default_factory=lambda: Path(os.getenv("DATA_DIR", "data")))
    record: bool = field(default_factory=lambda: os.getenv("RECORD", "1") == "1")
    telegram_token: str = field(default_factory=lambda: os.getenv("TELEGRAM_BOT_TOKEN", ""))
    telegram_chat_id: str = field(default_factory=lambda: os.getenv("TELEGRAM_CHAT_ID", ""))
    heartbeat_minutes: int = field(default_factory=lambda: int(os.getenv("HEARTBEAT_MINUTES", "60")))

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    ws_url: str
    dsn: str
    log_level: str
    debug_jsonl: str | None


def load() -> Config:
    debug_jsonl = os.environ.get("MATTER_DEBUG_JSONL", "").strip()
    return Config(
        ws_url=os.environ.get("MATTER_WS_URL", "ws://localhost:5580/ws"),
        dsn=os.environ["MATTER_DSN"],
        log_level=os.environ.get("MATTER_LOG_LEVEL", "INFO").upper(),
        debug_jsonl=debug_jsonl or None,
    )

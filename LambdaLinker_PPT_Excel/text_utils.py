from __future__ import annotations

from typing import Optional


def normalize_text(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = [line.strip() for line in text.split("\n")]
    return "\n".join(line for line in lines if line)


def truncate_text(text: str, max_chars: int) -> str:
    if max_chars <= 0:
        return ""
    if len(text) <= max_chars:
        return text
    return text[: max(0, max_chars - 1)] + "…"


def format_bullet_points(items: Optional[list[str]]) -> str:
    if not items:
        return ""
    return "\n".join(f"- {x}" for x in items if isinstance(x, str) and x.strip())

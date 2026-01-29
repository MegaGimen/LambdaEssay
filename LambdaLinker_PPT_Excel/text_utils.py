from __future__ import annotations

from typing import Optional


def normalize_text(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = [line.strip() for line in text.split("\n")]
    return "\n".join(line for line in lines if line)


def split_text_to_paragraphs(text: str) -> list[str]:
    normalized = normalize_text(text)
    paragraphs = [line for line in normalized.split("\n") if line.strip()]
    return paragraphs


def truncate_text(text: str, max_chars: int) -> str:
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 3] + "..."


def format_bullet_points(items: object) -> Optional[str]:
    if isinstance(items, list):
        lines = [f"- {item}" for item in items if isinstance(item, str) and item.strip()]
        return "\n".join(lines) if lines else None
    if isinstance(items, str):
        lines = [line.strip() for line in items.splitlines() if line.strip()]
        return "\n".join(f"- {line}" for line in lines) if lines else None
    return None


def extract_text_from_tool_result(result: object) -> str:
    if isinstance(result, str):
        return result
    if isinstance(result, dict):
        for key in ("text", "content", "result", "data", "markdown"):
            value = result.get(key)
            if isinstance(value, str):
                return value
        content = result.get("content")
        text = extract_text_from_content(content)
        if text is not None:
            return text
    if hasattr(result, "content"):
        text = extract_text_from_content(getattr(result, "content"))
        if text is not None:
            return text
    return str(result)


def extract_text_from_content(content: object) -> Optional[str]:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
                continue
            if isinstance(item, dict):
                if isinstance(item.get("text"), str):
                    parts.append(item["text"])
        if parts:
            return "\n".join(parts)
    return None
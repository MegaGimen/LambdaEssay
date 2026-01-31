from __future__ import annotations

import json
from typing import Optional


def parse_json_output(text: str) -> Optional[dict]:
    text = text.strip()
    if text.startswith("```"):
        text = strip_code_fence(text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return extract_json_object(text)


def strip_code_fence(text: str) -> str:
    lines = [line for line in text.splitlines() if not line.strip().startswith("```")]
    return "\n".join(lines).strip()


def extract_json_object(text: str) -> Optional[dict]:
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return None
    snippet = text[start : end + 1]
    try:
        return json.loads(snippet)
    except json.JSONDecodeError:
        return None

from __future__ import annotations

from typing import Iterable

try:
    from .text_utils import truncate_text
except ImportError:  # pragma: no cover - fallback for direct execution
    from text_utils import truncate_text


def render_document(
    paragraphs: Iterable[str],
    *,
    max_paragraphs: int,
    max_paragraph_chars: int,
    max_total_chars: int,
    doc_label: str,
) -> str:
    paragraphs_list = list(paragraphs)
    lines: list[str] = []
    total_chars = 0
    for idx, paragraph in enumerate(paragraphs_list[:max_paragraphs], start=1):
        snippet = truncate_text(paragraph, max_paragraph_chars)
        line = f"[{doc_label}-{idx}] {snippet}"
        if total_chars + len(line) + 1 > max_total_chars:
            lines.append("... 因超出 max_total_chars 已截断 ...")
            break
        lines.append(line)
        total_chars += len(line) + 1
    if len(paragraphs_list) > max_paragraphs:
        lines.append(f"...（还有 {len(paragraphs_list) - max_paragraphs} 个段落被省略）...")
    return "\n".join(lines).strip()

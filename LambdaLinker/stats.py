from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class DiffStats:
    paragraphs_a: int
    paragraphs_b: int
    chars_a: int
    chars_b: int
    added_paragraphs: Optional[int] = None
    removed_paragraphs: Optional[int] = None
    changed_paragraphs: Optional[int] = None
    added_chars: Optional[int] = None
    removed_chars: Optional[int] = None
    diff_blocks: Optional[int] = None


def compute_basic_stats(paragraphs_a: list[str], paragraphs_b: list[str]) -> DiffStats:
    return DiffStats(
        paragraphs_a=len(paragraphs_a),
        paragraphs_b=len(paragraphs_b),
        chars_a=sum(len(p) for p in paragraphs_a),
        chars_b=sum(len(p) for p in paragraphs_b),
    )

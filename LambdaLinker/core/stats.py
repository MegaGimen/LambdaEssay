from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class DiffStats:
    blocks_a: int
    blocks_b: int
    chars_a: int
    chars_b: int
    added_blocks: Optional[int] = None
    removed_blocks: Optional[int] = None


def compute_basic_stats(blocks_a: list[str], blocks_b: list[str]) -> DiffStats:
    return DiffStats(
        blocks_a=len(blocks_a),
        blocks_b=len(blocks_b),
        chars_a=sum(len(x) for x in blocks_a),
        chars_b=sum(len(x) for x in blocks_b),
    )

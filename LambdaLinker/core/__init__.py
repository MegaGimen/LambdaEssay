"""Office 文档语义对比工具 - 核心模块"""

from .agent import LLMInvoker, default_agent_from_env
from .lambdalinker import compare_word_docs, compare_ppt_decks, compare_excel_docs
from .visualizer import generate_html_report, generate_markdown_report
from .output_parser import parse_json_output
from .prompts import build_prompts
from .rendering import render_document
from .stats import DiffStats, compute_basic_stats
from .text_utils import (
    normalize_text,
    split_text_to_paragraphs,
    truncate_text,
    format_bullet_points,
    count_images_in_markdown,
)
from .word_reader import read_docx_paragraphs, read_docx_comments
from .ppt_reader import read_ppt_blocks

__all__ = [
    # Main functions
    "compare_word_docs",
    "compare_ppt_decks",
    "compare_excel_docs",
    # Visualization
    "generate_html_report",
    "generate_markdown_report",
    # Agent
    "LLMInvoker",
    "default_agent_from_env",
    # Utilities
    "parse_json_output",
    "build_prompts",
    "render_document",
    "compute_basic_stats",
    "DiffStats",
    "normalize_text",
    "split_text_to_paragraphs",
    "truncate_text",
    "format_bullet_points",
    "count_images_in_markdown",
    # Readers
    "read_docx_paragraphs",
    "read_docx_comments",
    "read_ppt_blocks",
]

from __future__ import annotations

import logging
import os
import re
import sys
from dataclasses import asdict
from typing import Any, Callable, Optional

from .agent import LLMInvoker, UserPrompt, default_agent_from_env
from .output_parser import parse_json_output
from .prompts import build_prompts
from .rendering import render_document
from .stats import DiffStats, compute_basic_stats
from .text_utils import format_bullet_points, normalize_text, count_images_in_markdown
from .word_reader import (
    format_comments_for_prompt,
    read_docx_comments,
    read_docx_paragraphs,
)
from .ppt_reader import read_ppt_blocks

# 动态导入 MCP 模块（避免相对导入问题）
def _get_mcp_office():
    try:
        from mcp_modules.mcp_office import convert_office_to_markdown
        return convert_office_to_markdown
    except ImportError:
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        try:
            from mcp_modules.mcp_office import convert_office_to_markdown
            return convert_office_to_markdown
        except ImportError:
            from mcp_office import convert_office_to_markdown
            return convert_office_to_markdown

convert_office_to_markdown = _get_mcp_office()


_IMAGE_MD_RE = re.compile(r"!\[([^\]]*)\]\((data:image/[^)]+)\)")
_IMAGE_HTML_RE = re.compile(r"<img[^>]*src=['\"](data:image/[^'\"]+)['\"][^>]*>", re.IGNORECASE)
_ALT_HTML_RE = re.compile(r"alt=['\"]([^'\"]*)['\"]", re.IGNORECASE)
_MAX_IMAGE_SIZE = 20 * 1024 * 1024  # 20MB limit for base64 images


def build_user_content_with_images(user_prompt: str) -> UserPrompt:
    """构建用户内容，移除 base64 图片以避免 API 错误"""
    # 移除 base64 图片，替换为文本标记
    def remove_base64_image(match):
        alt = match.group(1).strip()
        return f"[图片: {alt if alt else '图片'}]"

    # 处理 markdown 格式的 base64 图片
    user_prompt = re.sub(r'!\[([^\]]*)\]\(data:image/[^\)]+\)', remove_base64_image, user_prompt)

    # 处理 HTML 格式的 base64 图片
    user_prompt = re.sub(r'<img[^>]*src=[\'"]\(data:image/[^\)]*\)[^>]*>', r'[图片]', user_prompt, flags=re.IGNORECASE)

    return user_prompt


def merge_text_content(content: list[dict[str, Any]]) -> list[dict[str, Any]]:
    merged: list[dict[str, Any]] = []
    for item in content:
        if (
            merged
            and merged[-1].get("type") == "text"
            and item.get("type") == "text"
        ):
            merged[-1]["text"] = (merged[-1].get("text") or "") + (item.get("text") or "")
            continue
        merged.append(item)
    return merged


def count_image_inputs(user_content: UserPrompt) -> int:
    if isinstance(user_content, str):
        return 0
    return sum(1 for item in user_content if item.get("type") == "image_url")


def compare_word_docs(
    doc_a_path: str,
    doc_b_path: str,
    llm_client: Optional[LLMInvoker | Callable[[str, UserPrompt], str]] = None,
    *,
    max_diff_blocks: int = 80,
    max_block_paragraphs: int = 5,
    max_paragraph_chars: int = 500,
    max_doc_paragraphs: Optional[int] = None,
    max_doc_chars: int = 20000,
    language: str = "zh",
    use_mcp: bool = True,
    mcp_server: Optional[str] = None,
    mcp_config_path: Optional[str] = None,
    mcp_server_name: Optional[str] = None,
    include_comments: bool = False,
) -> dict:
    paragraphs_a = read_docx_paragraphs(
        doc_a_path,
        use_mcp=use_mcp,
        mcp_server=mcp_server,
        mcp_config_path=mcp_config_path,
        mcp_server_name=mcp_server_name,
    )
    paragraphs_b = read_docx_paragraphs(
        doc_b_path,
        use_mcp=use_mcp,
        mcp_server=mcp_server,
        mcp_config_path=mcp_config_path,
        mcp_server_name=mcp_server_name,
    )
    stats = compute_basic_stats(paragraphs_a, paragraphs_b)

    if max_doc_paragraphs is None:
        max_doc_paragraphs = max_diff_blocks

    doc_a_text = render_document(
        paragraphs_a,
        max_paragraphs=max_doc_paragraphs,
        max_paragraph_chars=max_paragraph_chars,
        max_total_chars=max_doc_chars,
        doc_label="A",
    )
    doc_b_text = render_document(
        paragraphs_b,
        max_paragraphs=max_doc_paragraphs,
        max_paragraph_chars=max_paragraph_chars,
        max_total_chars=max_doc_chars,
        doc_label="B",
    )

    if not include_comments and os.getenv("INCLUDE_COMMENTS", "").strip().lower() in {"1", "true", "yes"}:
        include_comments = True
    if include_comments:
        comments_a = read_docx_comments(doc_a_path) if doc_a_path.lower().endswith(".docx") else []
        comments_b = read_docx_comments(doc_b_path) if doc_b_path.lower().endswith(".docx") else []

        # 文档 A Comments
        doc_a_text += "\n\n[Comments]\n"
        if comments_a:
            doc_a_text += f"评论数量: {len(comments_a)}\n"
            doc_a_text += format_comments_for_prompt(comments_a)
        else:
            doc_a_text += "评论数量: 0 (无评论)\n"

        # 文档 B Comments
        doc_b_text += "\n\n[Comments]\n"
        if comments_b:
            doc_b_text += f"评论数量: {len(comments_b)}\n"
            doc_b_text += format_comments_for_prompt(comments_b)
        else:
            doc_b_text += "评论数量: 0 (无评论)\n"

    system_prompt, user_prompt = build_prompts(
        doc_a_name=os.path.basename(doc_a_path),
        doc_b_name=os.path.basename(doc_b_path),
        doc_a_text=doc_a_text,
        doc_b_text=doc_b_text,
        stats=asdict(stats),
        language=language,
    )

    if os.getenv("PRINT_PROMPTS", "").strip() in {"1", "true", "yes"}:
        print("=== SYSTEM PROMPT ===")
        print(system_prompt)
        print("\n=== USER PROMPT ===")
        print(user_prompt)

    user_content = build_user_content_with_images(user_prompt)
    raw_output = call_llm(llm_client, system_prompt, user_content)
    parsed = parse_json_output(raw_output)
    if parsed is None:
        return {"raw_output": raw_output, "stats": asdict(stats)}

    summary = parsed.get("summary")
    analysis = parsed.get("analysis")
    key_changes = parsed.get("key_changes")
    differences = format_bullet_points(summary)

    return {
        "summary": summary,
        "analysis": analysis,
        "key_changes": key_changes,
        "differences": differences,
        "raw_output": raw_output,
        "stats": asdict(stats),
    }


def compare_ppt_decks(
    ppt_a_path: str,
    ppt_b_path: str,
    llm_client: Optional[LLMInvoker | Callable[[str, UserPrompt], str]] = None,
    *,
    max_diff_blocks: int = 80,
    max_paragraph_chars: int = 700,
    max_doc_paragraphs: Optional[int] = None,
    max_doc_chars: int = 20000,
    language: str = "zh",
    use_mcp: bool = True,
    mcp_server: Optional[str] = None,
    mcp_config_path: Optional[str] = None,
    mcp_server_name: Optional[str] = None,
    max_slides: Optional[int] = None,
) -> dict:
    """
    读取两个 .pptx 文件（通过 MarkItDown MCP 转 Markdown），由 LLM 进行语义级别对比。
    """
    blocks_a = read_ppt_blocks(
        ppt_a_path,
        use_mcp=use_mcp,
        mcp_server=mcp_server,
        mcp_config_path=mcp_config_path,
        mcp_server_name=mcp_server_name,
        max_slides=max_slides,
    )
    blocks_b = read_ppt_blocks(
        ppt_b_path,
        use_mcp=use_mcp,
        mcp_server=mcp_server,
        mcp_config_path=mcp_config_path,
        mcp_server_name=mcp_server_name,
        max_slides=max_slides,
    )

    stats = compute_basic_stats(blocks_a, blocks_b)

    if max_doc_paragraphs is None:
        max_doc_paragraphs = max_diff_blocks

    doc_a_text = render_document(
        blocks_a,
        max_paragraphs=max_doc_paragraphs,
        max_paragraph_chars=max_paragraph_chars,
        max_total_chars=max_doc_chars,
        doc_label="A",
    )
    doc_b_text = render_document(
        blocks_b,
        max_paragraphs=max_doc_paragraphs,
        max_paragraph_chars=max_paragraph_chars,
        max_total_chars=max_doc_chars,
        doc_label="B",
    )

    system_prompt, user_prompt = build_prompts(
        doc_a_name=os.path.basename(ppt_a_path),
        doc_b_name=os.path.basename(ppt_b_path),
        doc_a_text=doc_a_text,
        doc_b_text=doc_b_text,
        stats=asdict(stats),
        language=language,
    )

    raw_output = call_llm(llm_client, system_prompt, user_prompt)
    parsed = parse_json_output(raw_output)
    if parsed is None:
        return {"raw_output": raw_output, "stats": asdict(stats)}

    summary = parsed.get("summary")
    analysis = parsed.get("analysis")
    key_changes = parsed.get("key_changes")
    differences = format_bullet_points(summary)

    return {
        "summary": summary,
        "analysis": analysis,
        "key_changes": key_changes,
        "differences": differences,
        "raw_output": raw_output,
        "stats": asdict(stats),
    }


def compare_excel_docs(
    excel_a_path: str,
    excel_b_path: str,
    llm_client: Optional[LLMInvoker | Callable[[str, UserPrompt], str]] = None,
    *,
    max_diff_blocks: int = 80,
    max_paragraph_chars: int = 700,
    max_doc_paragraphs: Optional[int] = None,
    max_doc_chars: int = 20000,
    language: str = "zh",
    use_mcp: bool = True,
    mcp_server: Optional[str] = None,
    mcp_config_path: Optional[str] = None,
    mcp_server_name: Optional[str] = None,
) -> dict:
    for path in (excel_a_path, excel_b_path):
        if not os.path.exists(path):
            raise FileNotFoundError(f"File not found: {path}")
        if not path.lower().endswith((".xlsx", ".xls")):
            raise ValueError(f"Only .xlsx/.xls files are supported: {path}")

    if not use_mcp:
        raise RuntimeError("Excel 读取需要 use_mcp=True（通过 MCP Office 转换）。")

    md_a = normalize_text(
        convert_office_to_markdown(
            excel_a_path,
            server=mcp_server,
            config_path=mcp_config_path,
            server_name=mcp_server_name,
        )
    )
    md_b = normalize_text(
        convert_office_to_markdown(
            excel_b_path,
            server=mcp_server,
            config_path=mcp_config_path,
            server_name=mcp_server_name,
        )
    )

    blocks_a = [md_a] if md_a else ["(Empty sheet or no readable content)"]
    blocks_b = [md_b] if md_b else ["(Empty sheet or no readable content)"]
    stats = compute_basic_stats(blocks_a, blocks_b)

    if max_doc_paragraphs is None:
        max_doc_paragraphs = max_diff_blocks

    doc_a_text = render_document(
        blocks_a,
        max_paragraphs=max_doc_paragraphs,
        max_paragraph_chars=max_paragraph_chars,
        max_total_chars=max_doc_chars,
        doc_label="A",
    )
    doc_b_text = render_document(
        blocks_b,
        max_paragraphs=max_doc_paragraphs,
        max_paragraph_chars=max_paragraph_chars,
        max_total_chars=max_doc_chars,
        doc_label="B",
    )

    system_prompt, user_prompt = build_prompts(
        doc_a_name=os.path.basename(excel_a_path),
        doc_b_name=os.path.basename(excel_b_path),
        doc_a_text=doc_a_text,
        doc_b_text=doc_b_text,
        stats=asdict(stats),
        language=language,
        doc_kind="Excel表格",
        unit_name="内容块",
    )

    raw_output = call_llm(llm_client, system_prompt, user_prompt)
    parsed = parse_json_output(raw_output)
    if parsed is None:
        return {"raw_output": raw_output, "stats": asdict(stats)}

    summary = parsed.get("summary")
    analysis = parsed.get("analysis")
    key_changes = parsed.get("key_changes")
    differences = format_bullet_points(summary)

    return {
        "summary": summary,
        "analysis": analysis,
        "key_changes": key_changes,
        "differences": differences,
        "raw_output": raw_output,
        "stats": asdict(stats),
    }


def call_llm(
    llm_client: Optional[LLMInvoker | Callable[[str, UserPrompt], str]],
    system_prompt: str,
    user_prompt: UserPrompt,
) -> str:
    if llm_client is None:
        llm_client = default_agent_from_env()
    if callable(llm_client):
        return llm_client(system_prompt, user_prompt)
    if hasattr(llm_client, "invoke"):
        return llm_client.invoke(system_prompt, user_prompt)
    raise TypeError("llm_client 必须是可调用对象或提供 invoke() 方法。")

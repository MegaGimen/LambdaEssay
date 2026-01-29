from __future__ import annotations

import os
from dataclasses import asdict
from typing import Callable, Optional

# try:
#     from .agent import LLMInvoker, default_agent_from_env
#     from .output_parser import parse_json_output
#     from .prompts import build_prompts
#     from .rendering import render_document
#     from .stats import DiffStats, compute_basic_stats
#     from .text_utils import format_bullet_points
#     from .word_reader import read_docx_paragraphs
#     from .ppt_reader import read_ppt_blocks
# except ImportError:  # pragma: no cover - fallback for direct execution
from agent import LLMInvoker, default_agent_from_env
from output_parser import parse_json_output
from prompts import build_prompts
from rendering import render_document
from stats import DiffStats, compute_basic_stats
from text_utils import format_bullet_points
# from word_reader import read_docx_paragraphs
from ppt_reader import read_ppt_blocks


# def compare_word_docs(
#     doc_a_path: str,
#     doc_b_path: str,
#     llm_client: Optional[LLMInvoker | Callable[[str, str], str]] = None,
#     *,
#     max_diff_blocks: int = 80,
#     max_block_paragraphs: int = 5,
#     max_paragraph_chars: int = 500,
#     max_doc_paragraphs: Optional[int] = None,
#     max_doc_chars: int = 20000,
#     language: str = "zh",
#     use_mcp: bool = True,
#     mcp_server: Optional[str] = None,
#     mcp_config_path: Optional[str] = None,
#     mcp_server_name: Optional[str] = None,
# ) -> dict:
#     paragraphs_a = read_docx_paragraphs(
#         doc_a_path,
#         use_mcp=use_mcp,
#         mcp_server=mcp_server,
#         mcp_config_path=mcp_config_path,
#         mcp_server_name=mcp_server_name,
#     )
#     paragraphs_b = read_docx_paragraphs(
#         doc_b_path,
#         use_mcp=use_mcp,
#         mcp_server=mcp_server,
#         mcp_config_path=mcp_config_path,
#         mcp_server_name=mcp_server_name,
#     )
#     stats = compute_basic_stats(paragraphs_a, paragraphs_b)
#
#     if max_doc_paragraphs is None:
#         max_doc_paragraphs = max_diff_blocks
#
#     doc_a_text = render_document(
#         paragraphs_a,
#         max_paragraphs=max_doc_paragraphs,
#         max_paragraph_chars=max_paragraph_chars,
#         max_total_chars=max_doc_chars,
#         doc_label="A",
#     )
#     doc_b_text = render_document(
#         paragraphs_b,
#         max_paragraphs=max_doc_paragraphs,
#         max_paragraph_chars=max_paragraph_chars,
#         max_total_chars=max_doc_chars,
#         doc_label="B",
#     )
#
#     system_prompt, user_prompt = build_prompts(
#         doc_a_name=os.path.basename(doc_a_path),
#         doc_b_name=os.path.basename(doc_b_path),
#         doc_a_text=doc_a_text,
#         doc_b_text=doc_b_text,
#         stats=asdict(stats),
#         language=language,
#     )
#
#     raw_output = call_llm(llm_client, system_prompt, user_prompt)
#     parsed = parse_json_output(raw_output)
#     if parsed is None:
#         return {"raw_output": raw_output, "stats": asdict(stats)}
#
#     summary = parsed.get("summary")
#     analysis = parsed.get("analysis")
#     key_changes = parsed.get("key_changes")
#     differences = format_bullet_points(summary)
#
#     return {
#         "summary": summary,
#         "analysis": analysis,
#         "key_changes": key_changes,
#         "differences": differences,
#         "raw_output": raw_output,
#         "stats": asdict(stats),
#     }


def compare_ppt_decks(
    ppt_a_path: str,
    ppt_b_path: str,
    llm_client: Optional[LLMInvoker | Callable[[str, str], str]] = None,
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


def call_llm(
    llm_client: Optional[LLMInvoker | Callable[[str, str], str]],
    system_prompt: str,
    user_prompt: str,
) -> str:
    if llm_client is None:
        llm_client = default_agent_from_env()
    if callable(llm_client):
        return llm_client(system_prompt, user_prompt)
    if hasattr(llm_client, "invoke"):
        return llm_client.invoke(system_prompt, user_prompt)
    raise TypeError("llm_client 必须是可调用对象或提供 invoke() 方法。")

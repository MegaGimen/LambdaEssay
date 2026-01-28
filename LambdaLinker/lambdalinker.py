from __future__ import annotations

import os
from dataclasses import asdict
from typing import Callable, Optional

try:
    from .agent import LLMInvoker, default_agent_from_env
    from .output_parser import parse_json_output
    from .prompts import build_prompts
    from .rendering import render_document
    from .stats import DiffStats, compute_basic_stats
    from .text_utils import format_bullet_points
    from .word_reader import (
        format_comments_for_prompt,
        read_docx_comments,
        read_docx_paragraphs,
    )
except ImportError:  # pragma: no cover - fallback for direct execution
    from agent import LLMInvoker, default_agent_from_env
    from output_parser import parse_json_output
    from prompts import build_prompts
    from rendering import render_document
    from stats import DiffStats, compute_basic_stats
    from text_utils import format_bullet_points
    from word_reader import format_comments_for_prompt, read_docx_comments, read_docx_paragraphs


def compare_word_docs(
    doc_a_path: str,
    doc_b_path: str,
    llm_client: Optional[LLMInvoker | Callable[[str, str], str]] = None,
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
    """读取两个 .docx 文件，由 LLM 进行语义级别对比。

    参数
    ----
    doc_a_path, doc_b_path : str
        .docx 文件路径。
    llm_client : object or callable
        需提供 `invoke(system_prompt, user_prompt)` 或可调用对象。
        若为 None，则使用环境变量 LLM_API_KEY/LLM_BASE_URL/LLM_MODEL_ID。
    max_diff_blocks, max_block_paragraphs
        语义模式下已弃用，仅为兼容保留。
    use_mcp, mcp_server
        为 True 时，通过 Office-Word-MCP-Server 读取文档文本。
    mcp_config_path, mcp_server_name
        指定 MCP 配置文件路径或服务名（默认 word-document-server）。
    """
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
        if comments_a:
            doc_a_text += "\n\n[Comments]\n" + format_comments_for_prompt(comments_a)
        if comments_b:
            doc_b_text += "\n\n[Comments]\n" + format_comments_for_prompt(comments_b)

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

    raw_output = call_llm(llm_client, system_prompt, user_prompt)
    parsed = parse_json_output(raw_output)
    if parsed is None:
        result = {
            "raw_output": raw_output,
            "stats": asdict(stats),
        }
        return result

    summary = parsed.get("summary")
    analysis = parsed.get("analysis")
    key_changes = parsed.get("key_changes")
    differences = format_bullet_points(summary)

    result = {
        "summary": summary,
        "analysis": analysis,
        "key_changes": key_changes,
        "differences": differences,
        "raw_output": raw_output,
        "stats": asdict(stats),
    }
    return result


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

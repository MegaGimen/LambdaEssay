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
    from .ppt_reader import read_pptx_deck
    from .ppt_visual_supplement import ppt_visual_supplement_markdown
except ImportError:  # pragma: no cover - fallback for direct execution
    from agent import LLMInvoker, default_agent_from_env
    from output_parser import parse_json_output
    from prompts import build_prompts
    from rendering import render_document
    from stats import DiffStats, compute_basic_stats
    from text_utils import format_bullet_points
    # from word_reader import read_docx_paragraphs
    from ppt_reader import read_pptx_deck
    from ppt_visual_supplement import ppt_visual_supplement_markdown

def _ppt_visual_trigger(ppt_meta: dict) -> tuple[bool, list[str]]:
    """根据结构化抽取的 meta 判断是否需要视觉补充。"""
    reasons: list[str] = []
    slides = int(ppt_meta.get("slides") or 0)
    if slides <= 0:
        return False, reasons

    pictures = int(ppt_meta.get("total_pictures") or 0)
    charts = int(ppt_meta.get("total_charts") or 0)
    tables = int(ppt_meta.get("total_tables") or 0)
    nontext_slides = int(ppt_meta.get("slides_with_nontext") or 0)
    text_chars = int(ppt_meta.get("total_text_chars") or 0)

    if (pictures + charts + tables) >= 5:
        reasons.append("图片/图表/表格对象较多，结构化抽取可能遗漏图中信息。")
    if nontext_slides / max(slides, 1) >= 0.4:
        reasons.append("包含非文本对象的幻灯片占比偏高，建议启用视觉补充。")
    if text_chars < 300 and (pictures + charts) > 0:
        reasons.append("文本总量偏少但存在图表/图片，内容可能主要靠视觉表达。")

    return (len(reasons) > 0), reasons


def _fuse_structured_visual_blocks(structured_blocks: list[str], visual_md_by_slide: dict[int, str]) -> list[str]:
    """结构化优先；视觉补充只追加，并标注 needs_check 避免 OCR 误读污染事实。"""
    fused: list[str] = []
    for block in structured_blocks:
        slide_idx = None
        if block.startswith("Slide "):
            head = block.splitlines()[0].strip()
            try:
                slide_idx = int(head.replace("Slide", "").strip())
            except Exception:
                slide_idx = None

        if slide_idx is not None and slide_idx in visual_md_by_slide:
            block = (
                block
                + "\n\n[Visual Supplement | needs_check]\n"
                + visual_md_by_slide[slide_idx].strip()
            )
        fused.append(block)
    return fused


def compare_ppt_decks(
    ppt_a_path: str,
    ppt_b_path: str,
    llm_client: Optional[LLMInvoker | Callable[[str, str], str]] = None,
    *,
    include_notes: bool = False,
    max_slides: Optional[int] = None,
    max_paragraph_chars: int = 700,
    max_doc_chars: int = 20000,
    language: str = "zh",
    # 视觉补充开关（建议默认 False，先保证结构化主干稳定）
    enable_visual_supplement: bool = False,
    # MCP/Office 相关参数（视觉补充用）
    mcp_server: Optional[str] = None,
    mcp_config_path: Optional[str] = None,
    mcp_server_name: Optional[str] = None,
    # 视觉补充最多处理多少页（防止成本/延迟爆炸）
    max_visual_pages: int = 6,
) -> dict:
    # 1) 结构化抽取
    deck_a = read_pptx_deck(ppt_a_path, include_notes=include_notes, max_slides=max_slides)
    deck_b = read_pptx_deck(ppt_b_path, include_notes=include_notes, max_slides=max_slides)

    blocks_a = deck_a.blocks
    blocks_b = deck_b.blocks

    # 2) trigger：决定是否需要视觉补充
    need_vis_a, reasons_a = _ppt_visual_trigger(deck_a.meta)
    need_vis_b, reasons_b = _ppt_visual_trigger(deck_b.meta)
    visual_recommended = need_vis_a or need_vis_b
    visual_reasons = sorted(set(reasons_a + reasons_b))

    # 3)（可选）视觉补充：只对“高风险页”做
    visual_status = "disabled"
    if enable_visual_supplement and visual_recommended:
        # 选页策略：优先图表/图片多、文本少的页
        def score(m: dict) -> tuple[int, int, int]:
            nontext = int(m.get("pictures", 0)) + int(m.get("charts", 0)) + int(m.get("tables", 0))
            text_chars = int(m.get("text_chars", 0))
            # nontext 多优先；text 少优先（取负数）；页号次优先
            return (nontext, -text_chars, -int(m.get("slide_index", 0)))

        slides_a = sorted(deck_a.slide_meta, key=score, reverse=True)
        slides_b = sorted(deck_b.slide_meta, key=score, reverse=True)
        pick_a = [int(s["slide_index"]) for s in slides_a[:max_visual_pages] if int(s.get("slide_index", 0)) > 0]
        pick_b = [int(s["slide_index"]) for s in slides_b[:max_visual_pages] if int(s.get("slide_index", 0)) > 0]

        try:
            md_a = ppt_visual_supplement_markdown(
                ppt_a_path,
                slide_indices_1based=pick_a,
                mcp_server=mcp_server,
                mcp_config_path=mcp_config_path,
                mcp_server_name=mcp_server_name,
            )
            md_b = ppt_visual_supplement_markdown(
                ppt_b_path,
                slide_indices_1based=pick_b,
                mcp_server=mcp_server,
                mcp_config_path=mcp_config_path,
                mcp_server_name=mcp_server_name,
            )
            blocks_a = _fuse_structured_visual_blocks(blocks_a, md_a)
            blocks_b = _fuse_structured_visual_blocks(blocks_b, md_b)
            visual_status = "enabled_ok"
        except Exception as exc:
            # 视觉通道失败不应影响主流程：降级为纯结构化
            visual_status = f"enabled_failed:{type(exc).__name__}"

    # 4) stats/render：完全复用（把“幻灯片块”当作“段落”）
    stats = compute_basic_stats(blocks_a, blocks_b)  # :contentReference[oaicite:10]{index=10}
    stats_dict = asdict(stats)
    stats_dict.update(
        {
            "ppt_meta_a": deck_a.meta,
            "ppt_meta_b": deck_b.meta,
            "visual_recommended": visual_recommended,
            "visual_reasons": visual_reasons,
            "visual_status": visual_status,
        }
    )

    doc_a_text = render_document(
        blocks_a,
        max_paragraphs=len(blocks_a),
        max_paragraph_chars=max_paragraph_chars,
        max_total_chars=max_doc_chars,
        doc_label="A",
    )
    doc_b_text = render_document(
        blocks_b,
        max_paragraphs=len(blocks_b),
        max_paragraph_chars=max_paragraph_chars,
        max_total_chars=max_doc_chars,
        doc_label="B",
    )

    # 5) prompts：建议你把 build_prompts 改成支持 doc_kind/unit_name
    #    如果你暂时不改 prompts，也能跑，只是文案里写“文档/段”不够贴切。:contentReference[oaicite:11]{index=11}
    system_prompt, user_prompt = build_prompts(
        doc_a_name=os.path.basename(ppt_a_path),
        doc_b_name=os.path.basename(ppt_b_path),
        doc_a_text=doc_a_text,
        doc_b_text=doc_b_text,
        stats=stats_dict,
        language=language,
        # 如果你已升级 build_prompts，可开启这两个参数：
        # doc_kind="PPT演示文稿",
        # unit_name="幻灯片块",
    )

    raw_output = call_llm(llm_client, system_prompt, user_prompt)  # 复用 call_llm :contentReference[oaicite:12]{index=12}
    parsed = parse_json_output(raw_output)  # 复用 output_parser :contentReference[oaicite:13]{index=13}
    if parsed is None:
        return {"doc_kind": "ppt", "raw_output": raw_output, "stats": stats_dict}

    summary = parsed.get("summary")
    analysis = parsed.get("analysis")
    key_changes = parsed.get("key_changes")
    differences = format_bullet_points(summary)

    return {
        "doc_kind": "ppt",
        "summary": summary,
        "analysis": analysis,
        "key_changes": key_changes,
        "differences": differences,
        "raw_output": raw_output,
        "stats": stats_dict,
        "visual_recommended": visual_recommended,
        "visual_reasons": visual_reasons,
        "visual_status": visual_status,
    }
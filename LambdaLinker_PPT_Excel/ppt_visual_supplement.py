from __future__ import annotations

import os
from pathlib import Path
from typing import Iterable, Optional

try:
    from .mcp_office import convert_to_pdf_via_mcp
    from .pdf_to_images import render_pdf_pages_to_png
    from .vision_slide_to_md import slide_image_to_markdown
except ImportError:  # pragma: no cover
    from mcp_office import convert_to_pdf_via_mcp
    from pdf_to_images import render_pdf_pages_to_png
    from vision_slide_to_md import slide_image_to_markdown


def ppt_visual_supplement_markdown(
    pptx_path: str,
    *,
    slide_indices_1based: Iterable[int],
    mcp_server: Optional[str] = None,
    mcp_config_path: Optional[str] = None,
    mcp_server_name: Optional[str] = None,
    cache_dir: str = ".cache_ppt_visual",
    vision_model: Optional[str] = None,
) -> dict[int, str]:
    """
    视觉补充主函数：
    - MCP convert_to_pdf(pptx) 得到 pdf
    - 本地渲染指定页为 png
    - 多模态模型把 png → Markdown
    返回：{slide_index: markdown}
    """
    cache = Path(cache_dir).resolve()
    cache.mkdir(parents=True, exist_ok=True)

    pdf_path = convert_to_pdf_via_mcp(
        pptx_path,
        server=mcp_server,
        config_path=mcp_config_path,
        server_name=mcp_server_name,
        output_dir=str(cache),
        # tool_args 可按你的 MCP server 要求扩展
        tool_args=None,
        tool_name="convert_to_pdf",
    )

    img_paths = render_pdf_pages_to_png(
        pdf_path,
        page_indices_1based=list(slide_indices_1based),
        out_dir=str(cache / "images"),
        dpi=int(os.getenv("PPT_VISUAL_DPI", "160")),
    )

    # page index 从文件名里解析出来（..._p{n}.png）
    out: dict[int, str] = {}
    for p in img_paths:
        name = Path(p).name
        # 兜底解析页号
        slide_idx = None
        for token in name.split("_"):
            if token.startswith("p") and token[1:].split(".")[0].isdigit():
                slide_idx = int(token[1:].split(".")[0])
                break
        if slide_idx is None:
            continue

        md = slide_image_to_markdown(p, model=vision_model)
        out[slide_idx] = md

    return out

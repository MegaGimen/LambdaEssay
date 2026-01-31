from __future__ import annotations

import os
import re
from typing import Optional

from .text_utils import normalize_text

# 动态导入 MCP 模块
def _get_mcp_office():
    try:
        from mcp_modules.mcp_office import convert_office_to_markdown
        return convert_office_to_markdown
    except ImportError:
        from mcp_office import convert_office_to_markdown
        return convert_office_to_markdown

convert_office_to_markdown = _get_mcp_office()


def read_ppt_blocks(
    path: str,
    *,
    use_mcp: bool = True,
    mcp_server: Optional[str] = None,
    mcp_config_path: Optional[str] = None,
    mcp_server_name: Optional[str] = None,
    max_slides: Optional[int] = None,
) -> list[str]:
    """
    PPT -> blocks（每个 block 对应一页/一段 slide markdown）

    - use_mcp=True：走 MarkItDown MCP convert_to_markdown
    - 返回的 blocks 可直接喂给 rendering.render_document（当作“段落块”）
    """
    if not path.lower().endswith(".pptx"):
        raise ValueError(f"仅支持 .pptx 文件: {path}")
    if not os.path.exists(path):
        raise FileNotFoundError(f"文件不存在: {path}")

    if not use_mcp:
        # 你们选择 MarkItDown 作为主方案时，一般不走这个分支。
        # 如果你想保留纯结构化读取，可在这里接 python-pptx。
        raise RuntimeError("当前 PPT 读取已切换为 MarkItDown MCP 方案，请将 use_mcp 设为 True。")

    md = convert_office_to_markdown(
        path,
        server=mcp_server,
        config_path=mcp_config_path,
        server_name=mcp_server_name,
    )
    md = normalize_text(md)

    blocks = split_markdown_into_slide_blocks(md)
    if max_slides is not None:
        blocks = blocks[:max_slides]

    if not blocks:
        return ["(Empty deck or no readable content)"]
    return blocks


def split_markdown_into_slide_blocks(md: str) -> list[str]:
    """
    兼容 MarkItDown 不同版本/不同格式输出：
    1) 优先按 “# Slide N / ## Slide N” 切分
    2) 其次按任意 Markdown 标题切分
    3) 再兜底按分隔线切分
    """
    md = (md or "").strip()
    if not md:
        return []

    # (1) Slide 标题切分
    slide_pat = re.compile(r"(?m)^(#{1,6}\s*Slide\s*\d+.*)$", flags=re.IGNORECASE)
    if slide_pat.search(md):
        parts = re.split(r"(?m)^(?=#{1,6}\s*Slide\s*\d+)", md, flags=re.IGNORECASE)
        parts = [p.strip() for p in parts if p.strip()]
        return parts

    # (2) 任意标题切分
    head_pat = re.compile(r"(?m)^(#{1,6}\s+.+)$")
    if head_pat.search(md):
        parts = re.split(r"(?m)^(?=#{1,6}\s+)", md)
        parts = [p.strip() for p in parts if p.strip()]
        # 如果切出来太碎（例如每行都是标题），仍然返回即可
        return parts

    # (3) 分隔线切分
    parts = re.split(r"\n-{3,}\n", md)
    parts = [p.strip() for p in parts if p.strip()]
    return parts if parts else [md]

"""MCP (Model Context Protocol) 相关模块"""

# 修复 mcp.types 导入问题（必须在导入 fastmcp 之前执行）
from ._patch_mcp import *  # noqa: F401

from .mcp_word import get_document_text_via_mcp
from .mcp_markitdown import convert_to_markdown_via_mcp
from .mcp_office import convert_office_to_markdown

__all__ = [
    "get_document_text_via_mcp",
    "convert_to_markdown_via_mcp",
    "convert_office_to_markdown",
]

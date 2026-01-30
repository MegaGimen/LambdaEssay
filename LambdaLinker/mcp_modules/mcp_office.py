from __future__ import annotations

import os
from typing import Optional

from .mcp_markitdown import convert_to_markdown_via_mcp
# except ImportError:  # pragma: no cover
#     from markitdown_mcp_server import convert_to_markdown_via_mcp


def convert_office_to_markdown(
    filename_or_uri: str,
    *,
    server: Optional[str] = None,
    config_path: Optional[str] = None,
    server_name: Optional[str] = None,
) -> str:
    """
    统一入口：Office 文件/URI -> Markdown

    环境变量：
      - MCP_OFFICE_SERVER / MCP_OFFICE_CONFIG / MCP_SERVER_NAME
    """
    server = (server or os.getenv("MCP_OFFICE_SERVER", "")).strip() or None
    config_path = (config_path or os.getenv("MCP_OFFICE_CONFIG", "")).strip() or None
    server_name = (server_name or os.getenv("MCP_SERVER_NAME", "")).strip() or None

    return convert_to_markdown_via_mcp(
        filename_or_uri,
        server=server,
        config_path=config_path,
        server_name=server_name,
    )

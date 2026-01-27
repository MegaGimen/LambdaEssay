from __future__ import annotations

import asyncio
import json
import os
from typing import Any, Optional

try:
    from fastmcp import Client
except Exception as exc:  # pragma: no cover - optional dependency
    raise RuntimeError("未安装 fastmcp，请先运行：pip install fastmcp") from exc

# 仅在需要时调用 MCP；当前默认流程可不启用 MCP。
# 能力列表见 mcp_capabilities.py（来自 Office-Word-MCP-Server 文档）。

try:
    from .text_utils import extract_text_from_tool_result
except ImportError:  # pragma: no cover - fallback for direct execution
    from text_utils import extract_text_from_tool_result

DEFAULT_SERVER_NAME = "word-document-server"


def get_document_text_via_mcp(
    filename: str,
    server: Optional[str] = None,
    config_path: Optional[str] = None,
    server_name: Optional[str] = None,
) -> str:
    server = (server or os.getenv("MCP_WORD_SERVER", "")).strip()
    config_path = (config_path or os.getenv("MCP_WORD_CONFIG", "")).strip()
    server_name = (server_name or os.getenv("MCP_WORD_SERVER_NAME", "")).strip()
    server_name = server_name or DEFAULT_SERVER_NAME

    if config_path:
        config = load_mcp_config(config_path)
        tool_name = resolve_tool_name(config, server_name)
        return run_async(_run_call(config, tool_name, filename, "get_document_text"))

    if server:
        return run_async(_run_call(server, "get_document_text", filename))

    raise ValueError("未配置 MCP_WORD_SERVER 或 MCP_WORD_CONFIG，无法连接 Office-Word-MCP-Server。")


def resolve_tool_name(config: dict, server_name: str) -> str:
    servers = config.get("mcpServers") or {}
    if isinstance(servers, dict) and len(servers) == 1:
        return "get_document_text"
    return f"{server_name}_get_document_text"


async def _run_call(
    target: Any,
    tool_name: str,
    filename: str,
    fallback_tool_name: Optional[str] = None,
) -> str:
    async with Client(target) as client:
        try:
            result = await client.call_tool(tool_name, {"filename": filename})
        except Exception:
            if fallback_tool_name is None:
                raise
            result = await client.call_tool(
                fallback_tool_name, {"filename": filename}
            )
        return extract_text_from_tool_result(result)


def load_mcp_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def run_async(coro: Any) -> Any:
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    raise RuntimeError("检测到已运行的事件循环，请在异步环境中直接调用。")

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any, Optional

# 注意：mcp.types 的修复在 mcp_modules/__init__.py 中处理
try:
    from fastmcp import Client
except Exception as exc:  # pragma: no cover - optional dependency
    raise RuntimeError("fastmcp is not installed, run: pip install fastmcp") from exc

try:
    from core.text_utils import extract_text_from_tool_result
except ImportError:  # pragma: no cover - fallback for direct execution
    from text_utils import extract_text_from_tool_result

DEFAULT_SERVER_NAME = "word-document-server"
DEFAULT_TOOL_NAME = "convert_to_markdown"


def get_document_text_via_mcp(
    filename: str,
    server: Optional[str] = None,
    config_path: Optional[str] = None,
    server_name: Optional[str] = None,
    include_images: Optional[bool] = None,
) -> str:
    server = (server or os.getenv("MCP_OFFICE_SERVER", "")).strip()
    config_path = (config_path or os.getenv("MCP_OFFICE_CONFIG", "")).strip()
    server_name = (server_name or os.getenv("MCP_SERVER_NAME", "")).strip()
    server_name = server_name or DEFAULT_SERVER_NAME

    uri = path_to_uri(filename)

    if config_path:
        config = load_mcp_config(config_path)
        tool_name = resolve_tool_name(config, server_name)
        return run_async(_run_call(config, tool_name, uri))

    if server:
        return run_async(_run_call(server, DEFAULT_TOOL_NAME, uri))

    raise ValueError("MCP_OFFICE_SERVER or MCP_OFFICE_CONFIG is required to reach MCP Server.")


def resolve_tool_name(config: dict, server_name: str) -> str:
    servers = config.get("mcpServers") or {}
    if isinstance(servers, dict) and len(servers) == 1:
        return DEFAULT_TOOL_NAME
    return f"{server_name}_{DEFAULT_TOOL_NAME}"


async def _run_call(
    target: Any,
    tool_name: str,
    uri: str,
) -> str:
    async with Client(target) as client:
        result = await client.call_tool(tool_name, {"uri": uri})
        return extract_text_from_tool_result(result)


def load_mcp_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def path_to_uri(path: str) -> str:
    return Path(path).resolve().as_uri()


def run_async(coro: Any) -> Any:
    """运行异步协程，兼容已有事件循环"""
    try:
        loop = asyncio.get_running_loop()
        # 如果已经在事件循环中，创建新的线程来运行
        import concurrent.futures
        import threading
        
        result = None
        exception = None
        
        def run_in_thread():
            nonlocal result, exception
            try:
                new_loop = asyncio.new_event_loop()
                asyncio.set_event_loop(new_loop)
                result = new_loop.run_until_complete(coro)
                new_loop.close()
            except Exception as e:
                exception = e
        
        thread = threading.Thread(target=run_in_thread)
        thread.start()
        thread.join()
        
        if exception:
            raise exception
        return result
        
    except RuntimeError:
        # 没有运行中的事件循环，直接运行
        return asyncio.run(coro)

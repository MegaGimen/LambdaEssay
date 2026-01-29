from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any, Optional, Dict, List

try:
    from mcp import ClientSession
    from mcp.client.stdio import stdio_client, StdioServerParameters
except ImportError:
    raise RuntimeError("未安装 mcp，请运行: pip install mcp")

try:
    from .text_utils import extract_text_from_tool_result
except ImportError:
    # Fallback
    def extract_text_from_tool_result(result: Any) -> str:
        if hasattr(result, "content") and isinstance(result.content, list):
            texts = [c.text for c in result.content if hasattr(c, "type") and c.type == 'text']
            return "\n".join(texts)
        if isinstance(result, list) and len(result) > 0:
            return getattr(result[0], "text", str(result[0]))
        return str(result)

DEFAULT_SERVER_NAME = "markitdown"
DEFAULT_TOOL_NAME = "convert_to_markdown"


def convert_to_markdown_via_mcp(
        filename_or_uri: str,
        server: Optional[str] = None,
        config_path: Optional[str] = None,
        server_name: Optional[str] = None,
) -> str:
    """
    调用 MarkItDown MCP 工具。
    """
    server = (server or os.getenv("MCP_MARKITDOWN_SERVER", "")).strip()
    config_path = (config_path or os.getenv("MCP_MARKITDOWN_CONFIG", "")).strip()
    server_name = (server_name or os.getenv("MCP_MARKITDOWN_SERVER_NAME", "")).strip()
    server_name = server_name or DEFAULT_SERVER_NAME

    uri = filename_or_uri
    if not _looks_like_uri(filename_or_uri):
        uri = path_to_uri(filename_or_uri)

    # 1. 使用配置文件 (mcp-config.json)
    if config_path:
        if not os.path.exists(config_path):
            raise FileNotFoundError(f"配置文件不存在: {config_path}")

        config = load_mcp_config(config_path)
        server_conf = _extract_server_config(config, server_name)
        if not server_conf:
            raise ValueError(f"在 {config_path} 中找不到名为 '{server_name}' 的服务器配置")

        cmd = server_conf.get("command")
        args = server_conf.get("args", [])

        return run_async(_run_call_stdio(cmd, args, DEFAULT_TOOL_NAME, uri))

    # 2. 直接指定脚本路径
    if server:
        # 明确使用 python 执行
        return run_async(_run_call_stdio("python", [server], DEFAULT_TOOL_NAME, uri))

    raise ValueError("未配置 MCP_MARKITDOWN_SERVER 或 MCP_MARKITDOWN_CONFIG。")


async def _run_call_stdio(
        command: str,
        args: List[str],
        tool_name: str,
        uri: str,
) -> str:
    """
    使用 Stdio 方式连接 MCP Server
    """
    server_params = StdioServerParameters(
        command=command,
        args=args,
        env=None  # 使用默认环境变量
    )

    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            
            # 列出可用工具以便调试
            tools = await session.list_tools()
            
            # 尝试调用工具
            try:
                result = await session.call_tool(tool_name, {"uri": uri})
            except Exception as e:
                # 尝试备用工具名
                fallback_name = f"markitdown_{tool_name}"
                try:
                    result = await session.call_tool(fallback_name, {"uri": uri})
                except Exception:
                    # 如果还是失败，抛出原始错误
                    raise e

            return extract_text_from_tool_result(result)


def _extract_server_config(config: Dict, server_name: str) -> Optional[Dict]:
    servers = config.get("mcpServers", {})
    if server_name in servers:
        return servers[server_name]
    if len(servers) == 1:
        return list(servers.values())[0]
    return None


def load_mcp_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def path_to_uri(path: str) -> str:
    return Path(path).resolve().as_uri()


def _looks_like_uri(s: str) -> bool:
    s = s.strip().lower()
    return s.startswith(("file:", "http:", "https:", "data:"))


def run_async(coro: Any) -> Any:
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)

    # 简单的防止重入检查
    if loop.is_running():
        raise RuntimeError("检测到正在运行的 Event Loop。请不要在异步环境(如 Jupyter)中调用此同步接口。")
    return loop.run_until_complete(coro)
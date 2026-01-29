from __future__ import annotations

import asyncio
import json
import os
import re
from pathlib import Path
from typing import Any, Optional

try:
    from fastmcp import Client
except Exception as exc:  # pragma: no cover - optional dependency
    raise RuntimeError("未安装 fastmcp,请先运行:pip install fastmcp") from exc

# 仅在需要时调用 MCP；当前默认流程可不启用 MCP。
# 能力列表见 mcp_capabilities.py（来自 Office-Word-MCP-Server 文档）。

try:
    from .text_utils import extract_text_from_tool_result
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
    server = (server or os.getenv("MCP_WORD_SERVER", "")).strip()
    config_path = (config_path or os.getenv("MCP_WORD_CONFIG", "")).strip()
    server_name = (server_name or os.getenv("MCP_WORD_SERVER_NAME", "")).strip()
    server_name = server_name or DEFAULT_SERVER_NAME
    if include_images is None:
        include_images = os.getenv("INCLUDE_IMAGES", "").strip().lower() in {"1", "true", "yes"}

    uri = path_to_uri(filename)

    if config_path:
        config = load_mcp_config(config_path)
        tool_name = resolve_tool_name(config, server_name)
        text = run_async(_run_call(config, tool_name, uri, DEFAULT_TOOL_NAME))
        return replace_images_with_alt(text) if include_images else strip_images_from_markdown(text)

    if server:
        text = run_async(_run_call(server, DEFAULT_TOOL_NAME, uri))
        return replace_images_with_alt(text) if include_images else strip_images_from_markdown(text)

    raise ValueError("未配置 MCP_WORD_SERVER 或 MCP_WORD_CONFIG，无法连接 MCP Server。")


def resolve_tool_name(config: dict, server_name: str) -> str:
    servers = config.get("mcpServers") or {}
    if isinstance(servers, dict) and len(servers) == 1:
        return DEFAULT_TOOL_NAME
    return f"{server_name}_{DEFAULT_TOOL_NAME}"


async def _run_call(
    target: Any,
    tool_name: str,
    uri: str,
    fallback_tool_name: Optional[str] = None,
) -> str:
    async with Client(target) as client:
        try:
            result = await client.call_tool(tool_name, {"uri": uri})
        except Exception:
            if fallback_tool_name is None:
                raise
            result = await client.call_tool(
                fallback_tool_name, {"uri": uri}
            )
        return extract_text_from_tool_result(result)


def load_mcp_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def path_to_uri(path: str) -> str:
    return Path(path).resolve().as_uri()


def run_async(coro: Any) -> Any:
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    raise RuntimeError("检测到已运行的事件循环，请在异步环境中直接调用。")


_IMAGE_MD_RE = re.compile(r"!\[([^\]]*)\]\([^\)]*\)")
_IMAGE_REF_RE = re.compile(r"!\[([^\]]*)\]\[[^\]]*\]")
_IMAGE_HTML_RE = re.compile(r"<img[^>]*>", re.IGNORECASE)
_ALT_HTML_RE = re.compile(r"alt=['\"]([^'\"]*)['\"]", re.IGNORECASE)


def strip_images_from_markdown(text: str) -> str:
    text = _IMAGE_HTML_RE.sub("", text)
    text = _IMAGE_MD_RE.sub("", text)
    text = _IMAGE_REF_RE.sub("", text)
    return text


def replace_images_with_alt(text: str) -> str:
    def label_from_alt(alt: str) -> str:
        alt = alt.strip()
        return alt if alt else "image"

    def md_repl(match: re.Match[str]) -> str:
        return f"[Image: {label_from_alt(match.group(1))}]"

    def ref_repl(match: re.Match[str]) -> str:
        return f"[Image: {label_from_alt(match.group(1))}]"

    def html_repl(match: re.Match[str]) -> str:
        alt_match = _ALT_HTML_RE.search(match.group(0))
        alt = alt_match.group(1) if alt_match else ""
        return f"[Image: {label_from_alt(alt)}]"

    text = _IMAGE_HTML_RE.sub(html_repl, text)
    text = _IMAGE_MD_RE.sub(md_repl, text)
    text = _IMAGE_REF_RE.sub(ref_repl, text)
    return text

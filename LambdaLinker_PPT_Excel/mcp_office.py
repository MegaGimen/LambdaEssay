from __future__ import annotations

import asyncio
import base64
import json
import os
from pathlib import Path
from typing import Any, Optional

try:
    from fastmcp import Client
except Exception as exc:  # pragma: no cover
    raise RuntimeError("未安装 fastmcp，请先运行：pip install fastmcp") from exc


def _run_async(coro: Any) -> Any:
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    raise RuntimeError("检测到已运行的事件循环，请在异步环境中直接调用。")


def _load_mcp_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _resolve_tool_name(config: dict, server_name: str, tool: str) -> str:
    # 和你们 mcp_word.py 一样的逻辑：单 server 不加前缀，多 server 加 server_name 前缀
    servers = config.get("mcpServers") or {}
    if isinstance(servers, dict) and len(servers) == 1:
        return tool
    return f"{server_name}_{tool}"


def _extract_path_or_bytes(result: object) -> tuple[Optional[str], Optional[bytes]]:
    """
    兼容不同 MCP server 的返回：
    - 可能直接返回字符串 path
    - 可能返回 dict：{'path'/'file_path'/'pdf_path': ...}
    - 可能返回 base64：{'data': '...'} or {'content': [{'type':'base64', 'data':...}]}
    """
    if isinstance(result, str):
        # 可能是 path，也可能是 base64（通常会很长）
        if len(result) > 2000 and all(c.isalnum() or c in "+/=\n\r" for c in result[:200]):
            try:
                return None, base64.b64decode(result)
            except Exception:
                return result, None
        return result, None

    if isinstance(result, dict):
        for k in ("pdf_path", "file_path", "path", "output_path", "result_path"):
            v = result.get(k)
            if isinstance(v, str) and v.strip():
                return v.strip(), None

        # bytes / base64
        data = result.get("data")
        if isinstance(data, (bytes, bytearray)):
            return None, bytes(data)
        if isinstance(data, str) and data.strip():
            try:
                return None, base64.b64decode(data)
            except Exception:
                pass

        content = result.get("content")
        if isinstance(content, list):
            for item in content:
                if isinstance(item, dict):
                    v = item.get("path") or item.get("file_path")
                    if isinstance(v, str) and v.strip():
                        return v.strip(), None
                    b64 = item.get("data")
                    if isinstance(b64, str) and b64.strip():
                        try:
                            return None, base64.b64decode(b64)
                        except Exception:
                            pass

    # 兜底
    return None, None


async def _call_tool(target: Any, tool_name: str, args: dict) -> object:
    async with Client(target) as client:
        return await client.call_tool(tool_name, args)


def convert_to_pdf_via_mcp(
    filename: str,
    *,
    server: Optional[str] = None,
    config_path: Optional[str] = None,
    server_name: Optional[str] = None,
    output_dir: Optional[str] = None,
    tool_args: Optional[dict] = None,
    tool_name: str = "convert_to_pdf",
) -> str:
    """
    用 MCP 调用 convert_to_pdf，把 Office 文件（docx/pptx/xlsx...视 server 支持）转换成 pdf。
    返回 pdf 的本地路径（或把 bytes 写到 output_dir）。
    """
    server = (server or os.getenv("MCP_OFFICE_SERVER", "")).strip()
    config_path = (config_path or os.getenv("MCP_OFFICE_CONFIG", "")).strip()
    server_name = (server_name or os.getenv("MCP_OFFICE_SERVER_NAME", "")).strip() or "office-server"

    args = {"filename": filename}
    if tool_args:
        args.update(tool_args)

    out_dir = Path(output_dir or os.getenv("MCP_OFFICE_OUTPUT_DIR", "") or ".").resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    if config_path:
        cfg = _load_mcp_config(config_path)
        real_tool = _resolve_tool_name(cfg, server_name, tool_name)
        result = _run_async(_call_tool(cfg, real_tool, args))
    elif server:
        result = _run_async(_call_tool(server, tool_name, args))
    else:
        raise ValueError("未配置 MCP_OFFICE_SERVER 或 MCP_OFFICE_CONFIG，无法连接 Office/MCP 服务。")

    path, data = _extract_path_or_bytes(result)
    if path:
        return path

    if data:
        # 写入 output_dir
        pdf_path = out_dir / (Path(filename).stem + ".pdf")
        pdf_path.write_bytes(data)
        return str(pdf_path)

    raise RuntimeError(f"MCP convert_to_pdf 返回无法解析：{type(result)}")

from __future__ import annotations

import json
import logging
import os
from pathlib import Path

import lambdalinker as ll


def resolve_mcp_server() -> dict:
    config_path = os.getenv("MCP_WORD_CONFIG", "").strip()
    server_name = os.getenv("MCP_WORD_SERVER_NAME", "").strip()
    server = os.getenv("MCP_WORD_SERVER", "").strip()

    if config_path:
        return {
            "mcp_config_path": config_path,
            "mcp_server_name": server_name or "word-document-server",
        }

    if not server:
        repo_root = Path(__file__).resolve().parents[1] / "Office-Word-MCP-Server"
        default_server = repo_root / "word_mcp_server.py"
        server = str(default_server)

    return {"mcp_server": server}


def main() -> None:
    base_dir = Path(__file__).resolve().parent 
    doc_a_path = base_dir / "a.docx"
    doc_b_path = base_dir / "b.docx"

    mcp_args = resolve_mcp_server()
    if "mcp_config_path" in mcp_args:
        print(f"使用 MCP 配置文件：{mcp_args['mcp_config_path']}")
    else:
        print(f"使用 MCP 服务器脚本：{mcp_args['mcp_server']}")

    use_mcp = os.getenv("USE_MCP", "").strip() != "0"
    result = ll.compare_word_docs(
        str(doc_a_path),
        str(doc_b_path),
        use_mcp=use_mcp,
        **(mcp_args if use_mcp else {}),
    )
    if not logging.getLogger().handlers:
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s %(levelname)s %(message)s",
        )
    logging.getLogger("run_test").info(
        "最终结果：\n%s", json.dumps(result, ensure_ascii=False, indent=2)
    )


if __name__ == "__main__":
    main()

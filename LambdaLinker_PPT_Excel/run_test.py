from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from dotenv import load_dotenv

# 加载 .env 文件
load_dotenv()

import lambdalinker as ll
from visualizer import generate_html_report, generate_markdown_report


def resolve_mcp_server() -> dict:
    """
    PPT/Excel 走 MarkItDown MCP（convert_to_markdown）。
    你已经写好了 config.json，建议用 MCP_OFFICE_CONFIG / MCP_MARKITDOWN_CONFIG 指定。

    连接优先级：
    1) MCP_OFFICE_CONFIG（推荐）
    2) MCP_MARKITDOWN_CONFIG
    3) MCP_OFFICE_SERVER（脚本路径或 target）
    4) MCP_MARKITDOWN_SERVER
    5) 默认：仓库根目录下的 markitdown_server.py（如果你把 server 脚本放在项目旁边）
    """
    config_path = (os.getenv("MCP_OFFICE_CONFIG", "") or os.getenv("MCP_MARKITDOWN_CONFIG", "")).strip()
    server_name = (os.getenv("MCP_OFFICE_SERVER_NAME", "") or os.getenv("MCP_MARKITDOWN_SERVER_NAME", "")).strip()
    server = (os.getenv("MCP_OFFICE_SERVER", "") or os.getenv("MCP_MARKITDOWN_SERVER", "")).strip()

    if config_path:
        return {
            "mcp_config_path": config_path,
            "mcp_server_name": server_name or "markitdown",
        }

    if not server:
        # 兜底：假设你把 markitdown_server.py 放在仓库根目录或项目相邻目录
        # 你也可以按自己实际位置调整
        repo_root = Path(__file__).resolve().parents[1]
        default_server = repo_root / "markitdown_mcp_server.py"
        server = str(default_server)

    return {"mcp_server": server}


def main() -> None:
    # ====== 你把 PPT 放到这里，并替换文件名即可 ======
    ppt_a = os.path.join("a.pptx")
    ppt_b = os.path.join("b.pptx")

    mcp_args = resolve_mcp_server()
    if "mcp_config_path" in mcp_args:
        print(f"使用 MCP 配置文件：{mcp_args['mcp_config_path']}")
        if mcp_args.get("mcp_server_name"):
            print(f"使用 MCP server_name：{mcp_args['mcp_server_name']}")
    else:
        print(f"使用 MCP 服务器脚本/target：{mcp_args['mcp_server']}")

    use_mcp = os.getenv("USE_MCP", "").strip() != "0"

    # 注意：PPT 读取方案已切换为 MarkItDown MCP，因此 use_mcp 建议保持 True
    if not use_mcp:
        raise RuntimeError("PPT 测试需要 USE_MCP=1（默认），因为读取依赖 MarkItDown MCP。")

    result = ll.compare_ppt_decks(
        ppt_a,
        ppt_b,
        use_mcp=True,
        **mcp_args,
    )

    if not logging.getLogger().handlers:
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s %(levelname)s %(message)s",
        )

    logging.getLogger("run_test_ppt").info(
        "最终结果：\n%s", json.dumps(result, ensure_ascii=False, indent=2)
    )
    
    # 生成可视化报告
    print("\n" + "="*60)
    print("[INFO] 正在生成可视化报告...")
    print("="*60)
    
    try:
        # 生成HTML报告
        html_path = generate_html_report(result, ppt_a, ppt_b, "diff_report.html")
        print(f"[SUCCESS] HTML报告已生成: {html_path}")
        
        # 生成Markdown报告
        md_path = generate_markdown_report(result, ppt_a, ppt_b, "diff_report.md")
        print(f"[SUCCESS] Markdown报告已生成: {md_path}")
        
        print("\n[TIP] 在浏览器中打开 diff_report.html 查看美观的可视化报告！")
        print("="*60)
    except Exception as e:
        print(f"[ERROR] 生成报告时出错: {e}")
        import traceback
        traceback.print_exc()


if __name__ == "__main__":
    main()

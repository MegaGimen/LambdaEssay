from __future__ import annotations

import json
import logging
import os
from pathlib import Path

import lambdalinker as ll
try:
    from docx import Document
except Exception as exc:  # pragma: no cover - optional dependency
    raise RuntimeError("未安装 python-docx，请先运行：pip install python-docx") from exc


def make_docx(path: str, paragraphs: list[str]) -> None:
    doc = Document()
    for paragraph in paragraphs:
        doc.add_paragraph(paragraph)
    doc.save(path)


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
    make_docx(
        "a.docx",
        [
            "项目概述：本项目用于搭建内部知识库系统，目标是提升检索效率与内容复用。",
            "范围：覆盖研发、运营、客服三类文档，支持标签与权限管理。",
            "里程碑：第一阶段完成数据迁移，第二阶段上线搜索与推荐。",
            "预算：总计 80 万元，其中基础设施 30 万、开发 40 万、培训 10 万。",
            "风险：数据清洗耗时、权限模型复杂、历史文档质量参差。",
        ],
    )
    make_docx(
        "b.docx",
        [
            "项目概述：本项目用于搭建企业级知识库系统，目标是提升检索效率与知识沉淀。",
            "范围：新增法务文档纳入，并支持标签、权限与审核流程。",
            "里程碑：第一阶段完成数据迁移与清洗，第二阶段上线搜索与推荐，第三阶段引入问答助手。",
            "预算：总计 95 万元，其中基础设施 35 万、开发 45 万、培训 15 万。",
            "风险：数据清洗耗时、权限模型复杂、历史文档质量参差、合规审核周期不确定。",
            "新增需求：要求支持多语言搜索与跨部门共享。",
        ],
    )

    mcp_args = resolve_mcp_server()
    if "mcp_config_path" in mcp_args:
        print(f"使用 MCP 配置文件：{mcp_args['mcp_config_path']}")
    else:
        print(f"使用 MCP 服务器脚本：{mcp_args['mcp_server']}")

    use_mcp = os.getenv("USE_MCP", "").strip() != "0"
    result = ll.compare_word_docs(
        "a.docx",
        "b.docx",
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

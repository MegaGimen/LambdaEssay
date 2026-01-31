#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""LambdaLinker 测试脚本

用于测试 Word/PPT/Excel 文档对比功能。
"""

import os
import sys
from pathlib import Path
from datetime import datetime

# 设置 UTF-8 编码输出（Windows 兼容）
if sys.platform == "win32":
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')

# 修复 mcp.types 导入问题（必须在任何其他导入之前执行）
try:
    import mcp.types as _mcp_types
    if 'mcp.types' not in sys.modules:
        sys.modules['mcp.types'] = _mcp_types
except ImportError:
    pass

# 添加项目根目录到 Python 路径
project_root = Path(__file__).parent
sys.path.insert(0, str(project_root))

# 加载 .env 文件
from dotenv import load_dotenv
env_path = project_root / ".env"
load_dotenv(env_path)

from core.lambdalinker import (
    compare_word_docs,
    compare_ppt_decks,
    compare_excel_docs,
)
from core.agent import default_agent_from_env


def save_report(doc_type: str, result: dict):
    """保存测试报告到 reports 文件夹"""
    reports_dir = project_root / "reports"
    reports_dir.mkdir(exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"diff_report_{doc_type}_{timestamp}.md"
    report_path = reports_dir / filename

    # 生成报告内容
    summary = result.get("summary", [])
    analysis = result.get("analysis", "")
    key_changes = result.get("key_changes", [])
    stats = result.get("stats", {})

    content = f"""# {doc_type.upper()} 文档对比报告

生成时间: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}

## 📊 统计信息

- 文档 A 块数: {stats.get('blocks_a', 'N/A')}
- 文档 B 块数: {stats.get('blocks_b', 'N/A')}
- 文档 A 字符数: {stats.get('chars_a', 'N/A')}
- 文档 B 字符数: {stats.get('chars_b', 'N/A')}

## 📋 差异摘要

"""

    if summary:
        for item in summary:
            content += f"- {item}\n"
    else:
        content += "无显著差异\n"

    content += "\n## 🔍 详细分析\n\n"
    content += analysis if analysis else "无详细分析信息"

    content += "\n\n## 📌 关键变更\n\n"

    if key_changes:
        for change in key_changes:
            change_type = change.get("type", "未知")
            detail = change.get("detail", "")
            content += f"### 📌 {change_type}\n{detail}\n\n"
    else:
        content += "无关键变更\n"

    # 保存报告
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"✅ 报告已保存到: {report_path}")
    return report_path


def test_word():
    """测试 Word 文档对比"""
    print("=" * 60)
    print("测试 Word 文档对比")
    print("=" * 60)

    llm_agent = default_agent_from_env()

    result = compare_word_docs(
        str(project_root / "examples/a.docx"),
        str(project_root / "examples/b.docx"),
        llm_agent,
        language="zh",
        use_mcp=True,
        include_comments=True,
    )

    # 保存报告
    save_report("word", result)

    # 输出差异摘要
    differences = result.get("differences", "")
    if differences:
        print("\n" + "=" * 60)
        print("差异摘要:")
        print("=" * 60)
        print(differences)

    return result


def test_ppt():
    """测试 PowerPoint 文档对比"""
    print("\n" + "=" * 60)
    print("测试 PowerPoint 文档对比")
    print("=" * 60)

    llm_agent = default_agent_from_env()

    result = compare_ppt_decks(
        str(project_root / "examples/a.pptx"),
        str(project_root / "examples/b.pptx"),
        llm_agent,
        language="zh",
        use_mcp=True,
    )

    # 保存报告
    save_report("ppt", result)

    # 输出差异摘要
    differences = result.get("differences", "")
    if differences:
        print("\n" + "=" * 60)
        print("差异摘要:")
        print("=" * 60)
        print(differences)

    return result


def test_excel():
    """测试 Excel 文档对比"""
    print("\n" + "=" * 60)
    print("测试 Excel 文档对比")
    print("=" * 60)

    llm_agent = default_agent_from_env()

    result = compare_excel_docs(
        str(project_root / "examples/a.xlsx"),
        str(project_root / "examples/b.xlsx"),
        llm_agent,
        language="zh",
        use_mcp=True,
    )

    # 保存报告
    save_report("excel", result)

    # 输出差异摘要
    differences = result.get("differences", "")
    if differences:
        print("\n" + "=" * 60)
        print("差异摘要:")
        print("=" * 60)
        print(differences)

    return result


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="LambdaLinker 测试脚本")
    parser.add_argument(
        "test_type",
        choices=["word", "ppt", "excel", "all"],
        help="测试类型: word, ppt, excel, all",
    )

    args = parser.parse_args()

    try:
        if args.test_type == "word":
            test_word()
        elif args.test_type == "ppt":
            test_ppt()
        elif args.test_type == "excel":
            test_excel()
        elif args.test_type == "all":
            test_word()
            test_ppt()
            test_excel()
            print("\n" + "=" * 60)
            print("✅ 所有测试完成！")
            print("=" * 60)
    except Exception as e:
        print(f"❌ 测试失败: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)

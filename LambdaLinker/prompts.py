from __future__ import annotations

import json
from typing import Tuple


def build_prompts(
    *,
    doc_a_name: str,
    doc_b_name: str,
    doc_a_text: str,
    doc_b_text: str,
    stats: dict,
    language: str,
) -> Tuple[str, str]:
    _ = language
    system_prompt = (
        "你是严谨的文档对比分析助手。"
        "请从语义层面对比两份文档内容的变化，不要只看顺序或字面一致，"
        "总结关键差异并分析其含义或影响。"
        "仅输出严格的 JSON。"
    )

    user_prompt = (
        f"文档A: {doc_a_name}\n"
        f"文档B: {doc_b_name}\n\n"
        f"统计信息:\n{json.dumps(stats, ensure_ascii=False)}\n\n"
        "文档A内容（按段编号）:\n"
        f"{doc_a_text}\n\n"
        "文档B内容（按段编号）:\n"
        f"{doc_b_text}\n\n"
        "请输出 JSON，字段如下：\n"
        "- summary: 关键差异要点列表（字符串数组，每项一条、简短）\n"
        "- analysis: 差异分析（字符串）\n"
        "- key_changes: 可选，列表，每项包含 type（新增/删除/修改/移动） 和 detail（说明）\n"
    )

    return system_prompt, user_prompt

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
    language: str = "zh",
    doc_kind: str = "文档",
    unit_name: str = "段落块",
) -> Tuple[str, str]:
    _ = language

    system_prompt = (
        "你是严谨的内容对比分析助手。"
        "请从语义层面对比两份内容的变化，不要只看顺序或字面一致，"
        "总结关键差异并分析其含义或影响。"
        "只输出严格 JSON，不要输出额外解释文字。"
    )

    user_prompt = (
        f"{doc_kind}A: {doc_a_name}\n"
        f"{doc_kind}B: {doc_b_name}\n\n"
        f"统计信息:\n{json.dumps(stats, ensure_ascii=False)}\n\n"
        f"{doc_kind}A内容（按{unit_name}编号）:\n{doc_a_text}\n\n"
        f"{doc_kind}B内容（按{unit_name}编号）:\n{doc_b_text}\n\n"
        "请输出 JSON，字段如下：\n"
        "- summary: 字符串数组，列出关键差异要点（每项一句话）\n"
        "- analysis: 字符串，解释这些差异意味着什么/影响是什么\n"
        "- key_changes: 可选，数组。每项包含：type(新增/删除/修改/移动)、detail(具体说明)\n"
        "注意：必须是合法 JSON（双引号、无尾逗号），不要用 ``` 包裹。\n"
    )

    return system_prompt, user_prompt

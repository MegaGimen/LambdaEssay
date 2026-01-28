from __future__ import annotations

import base64
import os
from pathlib import Path
from typing import Optional

try:
    from client import get_openai_client
except ImportError:  # pragma: no cover
    from .client import get_openai_client


def slide_image_to_markdown(
    image_path: str,
    *,
    model: Optional[str] = None,
    api_key: Optional[str] = None,
    base_url: Optional[str] = None,
    timeout: int = 90,
    max_retries: Optional[int] = None,
) -> str:
    """
    输入单张 slide PNG，输出该页的 Markdown 描述（包含可见文字、图表/流程内容的文字化）。
    需要模型支持 image_url 输入。
    """
    api_key = (api_key or os.getenv("LLM_API_KEY", "")).strip()
    base_url = (base_url or os.getenv("LLM_BASE_URL", "")).strip()
    model = (model or os.getenv("VISION_MODEL_ID", "") or os.getenv("LLM_MODEL_ID", "")).strip()
    if not model:
        raise ValueError("未配置 VISION_MODEL_ID 或 LLM_MODEL_ID。")

    client = get_openai_client(api_key, base_url, timeout=timeout, max_retries=max_retries)

    img_bytes = Path(image_path).read_bytes()
    b64 = base64.b64encode(img_bytes).decode("utf-8")
    data_url = f"data:image/png;base64,{b64}"

    system_prompt = (
        "你是演示文稿内容提取助手。"
        "请把这页幻灯片转成 Markdown，尽量保留结构（标题/要点/表格），"
        "并提取图表、流程图、截图中的可见文字。"
        "不要臆测看不到的内容。输出纯 Markdown，不要加代码块标记。"
    )
    user_text = "请把这页幻灯片内容转成 Markdown（标题、要点列表、表格、图中可见文字）。"

    messages = [
        {"role": "system", "content": system_prompt},
        {
            "role": "user",
            "content": [
                {"type": "text", "text": user_text},
                {"type": "image_url", "image_url": {"url": data_url}},
            ],
        },
    ]

    completion = client.chat.completions.create(
        model=model,
        messages=messages,
        temperature=0.0,
    )
    choices = getattr(completion, "choices", None) or []
    if not choices or not getattr(choices[0], "message", None):
        raise RuntimeError("多模态 LLM 响应为空。")
    return str(choices[0].message.content or "").strip()

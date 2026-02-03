from __future__ import annotations

import base64
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional, Protocol

from .client import get_openai_client


UserPrompt = str | list[dict[str, Any]]


class LLMInvoker(Protocol):
    def invoke(self, system_prompt: str, user_prompt: UserPrompt) -> str:  # pragma: no cover
        ...


@dataclass(frozen=True)
class LLMConfig:
    api_key: str
    base_url: str
    model: str
    temperature: float = 0.2
    timeout: int = 60
    max_tokens: Optional[int] = None
    max_retries: Optional[int] = None

    @staticmethod
    def from_env(prefix: str = "LLM_") -> "LLMConfig":
        api_key = os.getenv(f"{prefix}API_KEY", "").strip()
        base_url = os.getenv(f"{prefix}BASE_URL", "").strip()
        model = os.getenv(f"{prefix}MODEL_ID", "").strip()
        temperature = float(os.getenv(f"{prefix}TEMPERATURE", "0.2"))
        timeout = int(os.getenv(f"{prefix}TIMEOUT", "60"))
        max_tokens_val = os.getenv(f"{prefix}MAX_TOKENS", "").strip()
        max_tokens = int(max_tokens_val) if max_tokens_val else None
        max_retries_val = os.getenv(f"{prefix}MAX_RETRIES", "").strip()
        max_retries = int(max_retries_val) if max_retries_val else None
        return LLMConfig(
            api_key=api_key,
            base_url=base_url,
            model=model,
            temperature=temperature,
            timeout=timeout,
            max_tokens=max_tokens,
            max_retries=max_retries,
        )


class SemanticDiffAgent:
    """纯文本：用于 Word/PPT/Excel 的语义差异总结（summary/analysis/json）。"""

    def __init__(self, config: LLMConfig):
        if not config.model:
            raise ValueError("LLM_MODEL_ID 未配置。")
        self.config = config
        self.client = get_openai_client(
            config.api_key, config.base_url, timeout=config.timeout, max_retries=config.max_retries
        )

    def invoke(self, system_prompt: str, user_prompt: UserPrompt) -> str:
        resp = self.client.chat.completions.create(
            model=self.config.model,
            temperature=self.config.temperature,
            max_tokens=self.config.max_tokens,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ]
        )
        return (resp.choices[0].message.content or "").strip()


@dataclass(frozen=True)
class VisionConfig:
    api_key: str
    base_url: str
    model: str
    timeout: int = 90
    max_retries: Optional[int] = None

    @staticmethod
    def from_env() -> "VisionConfig":
        # 优先用 VISION_*，没有则回退 LLM_*
        api_key = (os.getenv("VISION_API_KEY") or os.getenv("LLM_API_KEY") or "").strip()
        base_url = (os.getenv("VISION_BASE_URL") or os.getenv("LLM_BASE_URL") or "").strip()
        model = (os.getenv("VISION_MODEL_ID") or os.getenv("LLM_MODEL_ID") or "").strip()
        timeout = int(os.getenv("VISION_TIMEOUT", "90"))
        max_retries_val = os.getenv("VISION_MAX_RETRIES", "").strip()
        max_retries = int(max_retries_val) if max_retries_val else None
        return VisionConfig(api_key=api_key, base_url=base_url, model=model, timeout=timeout, max_retries=max_retries)


class VisionMarkdownAgent:
    """图片 → Markdown：用于 PPT 视觉补充（从 slide 图片提取可见文字、表格、图表文字化描述）。"""

    def __init__(self, config: VisionConfig):
        if not config.model:
            raise ValueError("VISION_MODEL_ID（或 LLM_MODEL_ID）未配置，无法做视觉补充。")
        self.config = config
        self.client = get_openai_client(
            config.api_key, config.base_url, timeout=config.timeout, max_retries=config.max_retries
        )

    def image_to_markdown(self, image_path: str) -> str:
        img_bytes = Path(image_path).read_bytes()
        b64 = base64.b64encode(img_bytes).decode("utf-8")
        data_url = f"data:image/png;base64,{b64}"

        system_prompt = (
            "你是演示文稿内容提取助手。"
            "请把这页幻灯片转成 Markdown，尽量保留结构（标题/要点/表格），"
            "并提取图表、流程图、截图中的可见文字。"
            "不要臆测看不到的内容。输出纯 Markdown，不要加代码块标记。"
        )

        resp = self.client.chat.completions.create(
            model=self.config.model,
            temperature=0.0,
            messages=[
                {"role": "system", "content": system_prompt},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "请把这页幻灯片内容转成 Markdown（标题、要点列表、表格、图中可见文字）。"},
                        {"type": "image_url", "image_url": {"url": data_url}},
                    ],
                },
            ],
        )
        return (resp.choices[0].message.content or "").strip()


def default_agent_from_env() -> SemanticDiffAgent:
    return SemanticDiffAgent(LLMConfig.from_env())

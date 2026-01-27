from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional, Protocol
from client import get_openai_client


class LLMInvoker(Protocol):
    def invoke(self, system_prompt: str, user_prompt: str) -> str:  # pragma: no cover - protocol
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
    def from_env() -> "LLMConfig":
        api_key = os.getenv("LLM_API_KEY", "").strip()
        base_url = os.getenv("LLM_BASE_URL", "").strip()
        model = os.getenv("LLM_MODEL_ID", "").strip()
        temperature = float(os.getenv("LLM_TEMPERATURE", "0.2"))
        timeout = int(os.getenv("LLM_TIMEOUT", "60"))
        max_tokens_val = os.getenv("LLM_MAX_TOKENS", "").strip()
        max_tokens = int(max_tokens_val) if max_tokens_val else None
        max_retries_val = os.getenv("LLM_MAX_RETRIES", "").strip()
        max_retries = int(max_retries_val) if max_retries_val else None
        return LLMConfig(
            api_key=api_key,
            base_url=base_url.rstrip("/"),
            model=model,
            temperature=temperature,
            timeout=timeout,
            max_tokens=max_tokens,
            max_retries=max_retries,
        )


class SemanticDiffAgent:
    def __init__(self, config: LLMConfig) -> None:
        self.config = config
        self._client = get_openai_client(
            config.api_key,
            config.base_url,
            timeout=config.timeout,
            max_retries=config.max_retries,
        )

    def invoke(self, system_prompt: str, user_prompt: str) -> str:
        params = {
            "model": self.config.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": self.config.temperature,
        }
        if self.config.max_tokens is not None:
            params["max_tokens"] = self.config.max_tokens

        completion = self._client.chat.completions.create(**params)
        choices = getattr(completion, "choices", None) or []
        if not choices:
            raise RuntimeError("LLM 响应缺少 choices。")
        message = getattr(choices[0], "message", None)
        content = getattr(message, "content", None) if message else None
        if content is None:
            raise RuntimeError("LLM 响应缺少 content。")
        return str(content)


def default_agent_from_env() -> SemanticDiffAgent:
    load_env_file(default_env_path())
    return SemanticDiffAgent(LLMConfig.from_env())


def default_env_path() -> str:
    return os.path.join(os.path.dirname(__file__), ".env")


def load_env_file(path: str) -> None:
    if not os.path.exists(path):
        return
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for raw_line in handle:
                line = raw_line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip()
                if not key:
                    continue
                value = strip_env_quotes(value)
                if not os.getenv(key):
                    os.environ[key] = value
    except OSError:
        return


def strip_env_quotes(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value

from __future__ import annotations

from functools import lru_cache
from typing import Optional

try:
    from openai import OpenAI
except Exception as exc:  # pragma: no cover - import guard
    raise RuntimeError("未安装 openai SDK，请先运行：pip install openai") from exc


@lru_cache(maxsize=8)
def _cached_client(
    api_key: str,
    base_url: str,
    timeout: Optional[int],
    max_retries: Optional[int],
) -> OpenAI:
    client_kwargs: dict = {"api_key": api_key}
    if base_url:
        client_kwargs["base_url"] = base_url
    if timeout is not None:
        client_kwargs["timeout"] = timeout
    if max_retries is not None:
        client_kwargs["max_retries"] = max_retries
    return OpenAI(**client_kwargs)


def get_openai_client(
    api_key: str,
    base_url: str,
    *,
    timeout: Optional[int] = None,
    max_retries: Optional[int] = None,
) -> OpenAI:
    return _cached_client(api_key, base_url, timeout, max_retries)


def create_openai_client(api_key: str, base_url: str) -> OpenAI:
    return get_openai_client(api_key, base_url)

from __future__ import annotations

from functools import lru_cache
from typing import Optional

try:
    from openai import OpenAI
except Exception as exc:  # pragma: no cover
    raise RuntimeError("未安装 openai SDK，请先运行：pip install openai") from exc


@lru_cache(maxsize=8)
def _cached_client(
    api_key: str,
    base_url: str,
    timeout: Optional[int],
    max_retries: Optional[int],
) -> OpenAI:
    kwargs = {}
    if api_key:
        kwargs["api_key"] = api_key
    if base_url:
        kwargs["base_url"] = base_url
    if timeout is not None:
        kwargs["timeout"] = timeout
    if max_retries is not None:
        kwargs["max_retries"] = max_retries
    return OpenAI(**kwargs)


def get_openai_client(
    api_key: str,
    base_url: str,
    *,
    timeout: Optional[int] = None,
    max_retries: Optional[int] = None,
) -> OpenAI:
    return _cached_client(api_key, base_url, timeout, max_retries)

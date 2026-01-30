from __future__ import annotations

import os
from typing import Optional

from openai import OpenAI


def get_openai_client(
    api_key: str,
    base_url: str = "",
    timeout: int = 60,
    max_retries: Optional[int] = None,
) -> OpenAI:
    """创建 OpenAI 客户端"""
    kwargs = {"api_key": api_key}
    if base_url:
        kwargs["base_url"] = base_url
    if timeout:
        kwargs["timeout"] = timeout
    if max_retries:
        kwargs["max_retries"] = max_retries
    return OpenAI(**kwargs)

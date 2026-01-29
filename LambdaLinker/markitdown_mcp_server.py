from __future__ import annotations

import base64
import io
import mimetypes
import os
import re
from pathlib import Path
from typing import Optional, Tuple

from mcp.server.fastmcp import FastMCP
from markitdown import MarkItDown
from markitdown._stream_info import StreamInfo
from markitdown.converters._llm_caption import llm_caption
from openai import OpenAI

mcp = FastMCP("markitdown")


def _default_env_path() -> str:
    return str((Path(__file__).resolve().parent / ".env"))


def _load_env_file(path: str) -> None:
    try:
        with open(path, "r", encoding="utf-8-sig") as handle:
            for raw_line in handle:
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if key and not os.getenv(key):
                    os.environ[key] = value
    except OSError:
        return


def _env(name: str) -> str:
    return os.getenv(name, "").strip()


def build_markitdown_and_llm() -> Tuple[MarkItDown, Optional[OpenAI], Optional[str], str]:
    _load_env_file(_default_env_path())
    llm_api_key = _env("MARKITDOWN_LLM_API_KEY") or _env("LLM_API_KEY")
    llm_base_url = _env("MARKITDOWN_LLM_BASE_URL") or _env("LLM_BASE_URL")
    llm_model = _env("MARKITDOWN_LLM_MODEL")
    llm_prompt = _env("MARKITDOWN_LLM_PROMPT")
    docintel_endpoint = _env("MARKITDOWN_DOCINTEL_ENDPOINT")
    azure_api_key = _env("MARKITDOWN_AZURE_API_KEY")

    if azure_api_key and not _env("AZURE_API_KEY"):
        os.environ["AZURE_API_KEY"] = azure_api_key

    kwargs: dict[str, object] = {}
    if docintel_endpoint:
        kwargs["docintel_endpoint"] = docintel_endpoint

    llm_client: Optional[OpenAI] = None
    if llm_api_key and llm_model:
        client_kwargs: dict[str, object] = {"api_key": llm_api_key}
        if llm_base_url:
            client_kwargs["base_url"] = llm_base_url
        llm_client = OpenAI(**client_kwargs)
        kwargs["llm_client"] = llm_client
        kwargs["llm_model"] = llm_model
        if llm_prompt:
            kwargs["llm_prompt"] = llm_prompt

    return MarkItDown(**kwargs), llm_client, llm_model, llm_prompt


_IMAGE_DATA_MD_RE = re.compile(r"!\[([^\]]*)\]\((data:image/[^)]+)\)")
_DATA_URI_RE = re.compile(r"data:([^;]+);base64,([A-Za-z0-9+/=_-]+)")


def describe_images_in_markdown(
    markdown: str,
    *,
    client: OpenAI,
    model: str,
    prompt: str,
) -> str:
    cache: dict[str, str] = {}

    def sanitize_alt(text: str) -> str:
        text = re.sub(r"[\r\n]+", " ", text)
        text = text.replace("[", " ").replace("]", " ")
        return re.sub(r"\s+", " ", text).strip()

    def replace(match: re.Match[str]) -> str:
        alt = match.group(1) or ""
        data_uri = match.group(2)
        data_match = _DATA_URI_RE.match(data_uri)
        if not data_match:
            return match.group(0)
        content_type = data_match.group(1)
        b64 = data_match.group(2)
        if "..." in b64:
            return match.group(0)
        if b64 in cache:
            caption = cache[b64]
        else:
            try:
                image_bytes = base64.b64decode(b64)
            except Exception:
                return match.group(0)
            stream = io.BytesIO(image_bytes)
            extension = mimetypes.guess_extension(content_type) or ""
            stream_info = StreamInfo(mimetype=content_type, extension=extension)
            try:
                caption = llm_caption(
                    stream,
                    stream_info,
                    client=client,
                    model=model,
                    prompt=prompt,
                ) or ""
            except Exception:
                caption = ""
            caption = sanitize_alt(caption)
            cache[b64] = caption

        if caption:
            return f"![{caption}]({data_uri})"
        if alt:
            return match.group(0)
        return f"![image]({data_uri})"

    return _IMAGE_DATA_MD_RE.sub(replace, markdown)


@mcp.tool()
async def convert_to_markdown(uri: str) -> str:
    """Convert a resource described by an http:, https:, file: or data: URI to markdown."""
    md, llm_client, llm_model, llm_prompt = build_markitdown_and_llm()
    markdown = md.convert_uri(uri, keep_data_uris=True).markdown
    if llm_client and llm_model:
        markdown = describe_images_in_markdown(
            markdown,
            client=llm_client,
            model=llm_model,
            prompt=llm_prompt,
        )
    return markdown


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()

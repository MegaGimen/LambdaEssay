from __future__ import annotations

import os

from mcp.server.fastmcp import FastMCP
from markitdown import MarkItDown
from openai import OpenAI

mcp = FastMCP("markitdown")


def _env(name: str) -> str:
    return os.getenv(name, "").strip()


def build_markitdown() -> MarkItDown:
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

    if llm_api_key and llm_model:
        client_kwargs: dict[str, object] = {"api_key": llm_api_key}
        if llm_base_url:
            client_kwargs["base_url"] = llm_base_url
        kwargs["llm_client"] = OpenAI(**client_kwargs)
        kwargs["llm_model"] = llm_model
        if llm_prompt:
            kwargs["llm_prompt"] = llm_prompt

    return MarkItDown(**kwargs)


@mcp.tool()
async def convert_to_markdown(uri: str) -> str:
    """Convert a resource described by an http:, https:, file: or data: URI to markdown."""
    return build_markitdown().convert_uri(uri).markdown


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()

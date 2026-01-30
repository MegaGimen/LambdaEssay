from __future__ import annotations

import os
import re
import zipfile
import xml.etree.ElementTree as ET
from typing import Optional

from .text_utils import normalize_text, split_text_to_paragraphs, truncate_text
from openai import OpenAI

# 动态导入 MCP 相关模块
def _get_mcp_word():
    try:
        from mcp_modules.mcp_word import get_document_text_via_mcp
        return get_document_text_via_mcp
    except ImportError:
        from mcp_word import get_document_text_via_mcp
        return get_document_text_via_mcp

def _get_replace_images():
    try:
        from mcp_modules.markitdown_mcp_server import _replace_images_with_descriptions
        return _replace_images_with_descriptions
    except ImportError:
        from markitdown_mcp_server import _replace_images_with_descriptions
        return _replace_images_with_descriptions

get_document_text_via_mcp = _get_mcp_word()
_replace_images_with_descriptions = _get_replace_images()

DOCX_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
NSMAP = {"w": DOCX_NS}


def read_docx_paragraphs(
    path: str,
    *,
    use_mcp: bool = False,
    mcp_server: Optional[str] = None,
    mcp_config_path: Optional[str] = None,
    mcp_server_name: Optional[str] = None,
    include_images: Optional[bool] = None,
) -> list[str]:
    if not os.path.exists(path):
        raise FileNotFoundError(f"File not found: {path}")

    if use_mcp:
        if include_images is None:
            include_images = os.getenv("INCLUDE_IMAGES", "").strip().lower() in {"1", "true", "yes"}
        text = get_document_text_via_mcp(
            path,
            server=mcp_server,
            config_path=mcp_config_path,
            server_name=mcp_server_name,
            include_images=include_images,
        )

        # 如果启用了图片处理且配置了 LLM，后处理图片描述
        if include_images and 'data:image/' in text:
            llm_api_key = os.getenv("MARKITDOWN_LLM_API_KEY") or os.getenv("LLM_API_KEY")
            llm_base_url = os.getenv("MARKITDOWN_LLM_BASE_URL") or os.getenv("LLM_BASE_URL")
            llm_model = os.getenv("MARKITDOWN_LLM_MODEL")

            if llm_api_key and llm_model:
                try:
                    client_kwargs = {"api_key": llm_api_key}
                    if llm_base_url:
                        client_kwargs["base_url"] = llm_base_url
                    llm_client = OpenAI(**client_kwargs)
                    # 直接处理图片描述，绕过 MCP 缓存
                    text = _replace_images_with_descriptions(text, path, llm_client, llm_model, "请描述这张图片的内容，简洁明了")
                except Exception as e:
                    # 如果处理失败，使用原始文本
                    pass

        return split_text_to_paragraphs(text)

    if not path.lower().endswith(".docx"):
        raise ValueError(f"Only .docx files are supported without MCP: {path}")

    return read_docx_paragraphs_local(path)


def read_docx_paragraphs_local(path: str) -> list[str]:
    try:
        with zipfile.ZipFile(path) as zf:
            try:
                xml_bytes = zf.read("word/document.xml")
            except KeyError as exc:
                raise ValueError("Invalid .docx: missing word/document.xml") from exc
    except zipfile.BadZipFile as exc:
        raise ValueError(f"Invalid .docx (not a zip file): {path}") from exc

    root = ET.fromstring(xml_bytes)
    paragraphs: list[str] = []
    for para in root.iterfind(".//w:p", NSMAP):
        text = extract_paragraph_text(para)
        text = normalize_text(text)
        if text:
            paragraphs.append(text)
    return paragraphs


def read_docx_comments(path: str, *, max_context_chars: int = 200) -> list[dict]:
    try:
        with zipfile.ZipFile(path) as zf:
            try:
                comments_xml = zf.read("word/comments.xml")
            except KeyError:
                return []
            try:
                document_xml = zf.read("word/document.xml")
            except KeyError as exc:
                raise ValueError("Invalid .docx: missing word/document.xml") from exc
    except zipfile.BadZipFile as exc:
        raise ValueError(f"Invalid .docx (not a zip file): {path}") from exc

    comments_root = ET.fromstring(comments_xml)
    document_root = ET.fromstring(document_xml)

    comment_map: dict[str, dict] = {}
    for node in comments_root.findall("w:comment", NSMAP):
        comment_id = node.get(f"{{{DOCX_NS}}}id")
        author = node.get(f"{{{DOCX_NS}}}author")
        date = node.get(f"{{{DOCX_NS}}}date")
        text_parts = [t.text for t in node.findall(".//w:t", NSMAP) if t.text]
        text = normalize_text("".join(text_parts))
        if comment_id is None:
            continue
        comment_map[comment_id] = {
            "id": comment_id,
            "author": author,
            "date": date,
            "text": text,
        }

    if not comment_map:
        return []

    results: list[dict] = []
    para_index = 0
    for para in document_root.iterfind(".//w:p", NSMAP):
        para_index += 1
        para_text = normalize_text(extract_paragraph_text(para))
        if not para_text:
            continue

        active_ids: list[str] = []
        scoped_text: dict[str, list[str]] = {}
        for node in para.iter():
            if node.tag == f"{{{DOCX_NS}}}commentRangeStart":
                comment_id = node.get(f"{{{DOCX_NS}}}id")
                if comment_id is None:
                    continue
                if comment_id not in active_ids:
                    active_ids.append(comment_id)
                scoped_text.setdefault(comment_id, [])
                continue
            if node.tag == f"{{{DOCX_NS}}}commentRangeEnd":
                comment_id = node.get(f"{{{DOCX_NS}}}id")
                if comment_id is None:
                    continue
                if comment_id in active_ids:
                    active_ids.remove(comment_id)
                continue
            if node.tag == f"{{{DOCX_NS}}}t" and active_ids:
                node_text = node.text or ""
                for cid in active_ids:
                    scoped_text.setdefault(cid, []).append(node_text)

        for comment_id, parts in scoped_text.items():
            comment = comment_map.get(comment_id)
            if not comment:
                continue
            context_text = normalize_text("".join(parts)) or para_text
            results.append(
                {
                    **comment,
                    "paragraph_index": para_index,
                    "paragraph_text": truncate_text(context_text, max_context_chars),
                }
            )

    return results


def format_comments_for_prompt(comments: list[dict]) -> str:
    lines = []
    for item in comments:
        author = item.get("author") or "unknown"
        date = item.get("date") or "unknown"
        text = item.get("text") or ""
        para_index = item.get("paragraph_index")
        para_text = item.get("paragraph_text") or ""
        lines.append(
            f"- para={para_index} author={author} date={date} comment={text} context={para_text}"
        )
    return "\n".join(lines)


def extract_paragraph_text(para: ET.Element) -> str:
    parts: list[str] = []
    for node in para.iter():
        if node.tag == f"{{{DOCX_NS}}}t":
            parts.append(node.text or "")
        elif node.tag == f"{{{DOCX_NS}}}tab":
            parts.append("\t")
        elif node.tag == f"{{{DOCX_NS}}}br":
            parts.append("\n")
    return "".join(parts)

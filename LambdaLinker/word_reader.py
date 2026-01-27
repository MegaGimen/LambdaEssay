from __future__ import annotations

import os
import zipfile
import xml.etree.ElementTree as ET
from typing import Optional

try:
    from .mcp_word import get_document_text_via_mcp
    from .text_utils import normalize_text, split_text_to_paragraphs
except ImportError:  # pragma: no cover - fallback for direct execution
    from mcp_word import get_document_text_via_mcp
    from text_utils import normalize_text, split_text_to_paragraphs

DOCX_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
NSMAP = {"w": DOCX_NS}


def read_docx_paragraphs(
    path: str,
    *,
    use_mcp: bool = False,
    mcp_server: Optional[str] = None,
    mcp_config_path: Optional[str] = None,
    mcp_server_name: Optional[str] = None,
) -> list[str]:
    if not path.lower().endswith(".docx"):
        raise ValueError(f"仅支持 .docx 文件: {path}")
    if not os.path.exists(path):
        raise FileNotFoundError(f"文件不存在: {path}")

    if use_mcp:
        text = get_document_text_via_mcp(
            path,
            server=mcp_server,
            config_path=mcp_config_path,
            server_name=mcp_server_name,
        )
        return split_text_to_paragraphs(text)

    return read_docx_paragraphs_local(path)


def read_docx_paragraphs_local(path: str) -> list[str]:
    try:
        with zipfile.ZipFile(path) as zf:
            try:
                xml_bytes = zf.read("word/document.xml")
            except KeyError as exc:
                raise ValueError("无效 .docx：缺少 word/document.xml") from exc
    except zipfile.BadZipFile as exc:
        raise ValueError(f"无效 .docx（不是 zip 文件）: {path}") from exc

    root = ET.fromstring(xml_bytes)
    paragraphs: list[str] = []
    for para in root.iterfind(".//w:p", NSMAP):
        text = extract_paragraph_text(para)
        text = normalize_text(text)
        if text:
            paragraphs.append(text)
    return paragraphs


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

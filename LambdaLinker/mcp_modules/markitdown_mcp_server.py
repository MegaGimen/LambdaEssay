from __future__ import annotations

import os
import re
import zipfile
import tempfile
from pathlib import Path

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


def _generate_image_description(image_path: str, llm_client: OpenAI, llm_model: str, llm_prompt: str) -> str:
    """为图片文件生成描述"""
    import base64

    try:
        # 读取图片并转换为 base64
        with open(image_path, "rb") as f:
            image_bytes = f.read()

        # 检查图片大小
        if len(image_bytes) > 5 * 1024 * 1024:  # 5MB
            return "[图片过大，已省略详细描述]"

        # 转换为 base64 data URL
        ext = Path(image_path).suffix.lower()
        if ext == ".png":
            mime_type = "image/png"
        elif ext in (".jpg", ".jpeg"):
            mime_type = "image/jpeg"
        elif ext == ".gif":
            mime_type = "image/gif"
        else:
            mime_type = "image/png"

        b64_data = base64.b64encode(image_bytes).decode("utf-8")
        data_url = f"data:{mime_type};base64,{b64_data}"

        # 调用 LLM 生成描述
        response = llm_client.chat.completions.create(
            model=llm_model,
            messages=[{
                "role": "user",
                "content": [
                    {"type": "text", "text": llm_prompt or "请描述这张图片的内容，简洁明了。"},
                    {"type": "image_url", "image_url": {"url": data_url}}
                ]
            }],
            max_tokens=300,
            temperature=0
        )
        description = response.choices[0].message.content or "无法生成图片描述"
        return f"[图片: {description}]"

    except Exception as e:
        return f"[图片描述生成失败: {str(e)[:50]}]"


def _extract_images_from_docx(docx_path: str) -> list[dict]:
    """直接从 docx 文件中提取图片"""
    images = []
    try:
        with zipfile.ZipFile(docx_path) as zf:
            # 查找所有媒体文件
            for name in zf.namelist():
                if name.startswith('word/media/'):
                    # 提取文件名和扩展名
                    filename = Path(name).name
                    ext = Path(name).suffix.lower()

                    # 读取图片数据
                    with zf.open(name) as img_file:
                        image_bytes = img_file.read()

                    images.append({
                        'filename': filename,
                        'ext': ext,
                        'bytes': image_bytes,
                        'size': len(image_bytes)
                    })
    except Exception as e:
        print(f"Error extracting images: {e}")

    return images


def _replace_images_with_descriptions(markdown: str, docx_path: str, llm_client: OpenAI, llm_model: str, llm_prompt: str) -> str:
    """将 markdown 中的图片引用替换为 LLM 生成的描述"""

    # 从 docx 中提取所有图片
    docx_images = _extract_images_from_docx(docx_path)

    if not docx_images:
        # 如果没有提取到图片，使用原始的 base64 方法
        return _replace_base64_images_with_descriptions(markdown, docx_path, llm_client, llm_model, llm_prompt)

    # 为每个图片生成描述
    image_descriptions = []
    for img_info in docx_images:
        if img_info['size'] > 5 * 1024 * 1024:  # 5MB
            desc = f"[图片: {img_info['filename']}, 图片过大，已省略详细描述]"
        else:
            # 保存为临时文件
            with tempfile.NamedTemporaryFile(delete=False, suffix=img_info['ext']) as tmp:
                tmp.write(img_info['bytes'])
                tmp_path = tmp.name

            try:
                desc = _generate_image_description(tmp_path, llm_client, llm_model, llm_prompt)
            except Exception as e:
                desc = f"[图片: {img_info['filename']}, 描述生成失败: {str(e)[:30]}]"

            # 清理临时文件
            try:
                os.unlink(tmp_path)
            except:
                pass

        image_descriptions.append(desc)

    # 替换 markdown 中的图片引用
    # 使用简单的替换策略：按顺序替换 ![...]() 为描述
    def replace_image(match):
        nonlocal image_descriptions
        if image_descriptions:
            desc = image_descriptions.pop(0)
            return desc
        return match.group(0)

    pattern = r'!\[([^\]]*)\]\([^)]+\)'
    result = re.sub(pattern, replace_image, markdown)

    return result


def _replace_base64_images_with_descriptions(markdown: str, docx_path: str, llm_client: OpenAI, llm_model: str, llm_prompt: str) -> str:
    """将 markdown 中的 base64 图片替换为 LLM 生成的描述（备用方法）"""

    # 匹配 ![alt](data:image/...) 格式
    pattern = r'!\[([^\]]*)\]\((data:image/[a-zA-Z]+;base64,[^)]+)\)'

    def replace_image(match):
        alt = match.group(1).strip()
        data_uri = match.group(2)

        try:
            # 提取 base64 数据
            if ';base64,' in data_uri:
                header, base64_data = data_uri.split(';base64,', 1)
            elif 'base64,' in data_uri:
                header, base64_data = data_uri.split('base64,', 1)
            else:
                return match.group(0)

            # 解码 base64
            import base64
            image_bytes = base64.b64decode(base64_data)

            # 检查图片大小
            if len(image_bytes) > 5 * 1024 * 1024:  # 5MB
                return f'[图片: {alt}](图片过大，已省略详细描述)'

            # 保存为临时文件
            with tempfile.NamedTemporaryFile(delete=False, suffix='.png') as tmp:
                tmp.write(image_bytes)
                tmp_path = tmp.name

            # 生成描述
            description = _generate_image_description(tmp_path, llm_client, llm_model, llm_prompt)

            # 清理临时文件
            try:
                os.unlink(tmp_path)
            except:
                pass

            return description

        except Exception as e:
            return f'[图片: {alt}](描述生成失败)'

    return re.sub(pattern, replace_image, markdown)


def _extract_and_describe_docx_images(docx_path: str, markdown: str, llm_client: OpenAI, llm_model: str, llm_prompt: str) -> str:
    """处理 docx 文件中的图片（base64 格式）并生成描述"""
    return _replace_base64_images_with_descriptions(markdown, docx_path, llm_client, llm_model, llm_prompt)


@mcp.tool()
async def convert_to_markdown(uri: str) -> str:
    """Convert a resource described by an http:, https:, file: or data: URI to markdown.

    For .docx files with images, will extract images and generate LLM descriptions.
    """
    md = build_markitdown()
    result = md.convert_uri(uri)

    # 获取 markdown 内容
    if hasattr(result, 'text_content') and result.text_content:
        markdown = result.text_content
    else:
        markdown = result.markdown

    # 检查是否是 docx 文件且有图片
    is_docx = uri.lower().endswith('.docx') or (uri.startswith('file://') and uri.lower().endswith('.docx'))
    has_images = 'data:image/' in markdown

    if is_docx and has_images:
        # 获取文件路径
        if uri.startswith('file://'):
            from urllib.parse import unquote
            file_path = unquote(uri[7:])
            # 修复 Windows 路径：移除开头的 /
            if file_path.startswith('/') and len(file_path) > 2 and file_path[2] == ':':
                file_path = file_path[1:]
        else:
            file_path = uri

        # 获取 LLM 配置
        llm_api_key = _env("MARKITDOWN_LLM_API_KEY") or _env("LLM_API_KEY")
        llm_base_url = _env("MARKITDOWN_LLM_BASE_URL") or _env("LLM_BASE_URL")
        llm_model = _env("MARKITDOWN_LLM_MODEL")
        llm_prompt = _env("MARKITDOWN_LLM_PROMPT")

        if llm_api_key and llm_model:
            client_kwargs = {"api_key": llm_api_key}
            if llm_base_url:
                client_kwargs["base_url"] = llm_base_url
            llm_client = OpenAI(**client_kwargs)

            # 提取图片并生成描述
            markdown = _replace_images_with_descriptions(markdown, file_path, llm_client, llm_model, llm_prompt or "")

    return markdown


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()

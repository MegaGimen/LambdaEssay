#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""LambdaLinker FastAPI 服务器

提供 AI 文档对比的 HTTP API 接口，供 Dart 后端调用。
"""

import sys
import logging
from pathlib import Path
from typing import Optional

# 设置 UTF-8 编码（Windows 兼容）
if sys.platform == "win32":
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')

# 添加项目根目录到路径
project_root = Path(__file__).parent
sys.path.insert(0, str(project_root))

# 修复 mcp.types 导入问题
try:
    import mcp.types as _mcp_types
    if 'mcp.types' not in sys.modules:
        sys.modules['mcp.types'] = _mcp_types
except ImportError:
    pass

from fastapi import FastAPI, HTTPException, UploadFile, File, Form, Request, Depends
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from dotenv import load_dotenv
import shutil
import tempfile
import os
import json

# 加载环境变量
load_dotenv(project_root / ".env")

from core.lambdalinker import compare_word_docs, compare_ppt_decks, compare_excel_docs
from core.agent import default_agent_from_env
from core.cache_manager import get_cache_manager

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# 创建 FastAPI 应用
app = FastAPI(
    title="LambdaLinker API",
    description="AI 文档对比服务",
    version="1.0.0"
)

# 添加 CORS 支持
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ============ 数据模型 ============

class CompareRequest(BaseModel):
    """文档对比请求"""
    file_a: str = Field(..., description="文件A的绝对路径")
    file_b: str = Field(..., description="文件B的绝对路径")
    doc_type: str = Field(..., description="文档类型: word, ppt, excel")
    use_cache: bool = Field(True, description="是否使用缓存")
    use_mcp: bool = Field(True, description="是否使用MCP服务")
    commit_a: Optional[str] = Field(None, description="文件A的commit ID（用于缓存键）")
    commit_b: Optional[str] = Field(None, description="文件B的commit ID（用于缓存键）")


class CompareResponse(BaseModel):
    """文档对比响应"""
    success: bool
    doc_type: str
    cached: bool = Field(..., description="是否使用了缓存")
    result: dict


class CacheStatsResponse(BaseModel):
    """缓存统计响应"""
    enabled: bool
    cache_dir: str = ""
    total_entries: int = 0
    total_size_mb: float = 0.0
    max_entries: int = 0
    max_size_mb: int = 0


class ErrorResponse(BaseModel):
    """错误响应"""
    success: bool = False
    error: str


# ============ API 端点 ============

@app.get("/")
async def root():
    """根路径"""
    return {
        "name": "LambdaLinker API",
        "version": "1.0.0",
        "status": "running",
        "endpoints": {
            "compare": "POST /compare",
            "cache_stats": "GET /cache/stats",
            "clear_cache": "DELETE /cache",
            "health": "GET /health"
        }
    }


@app.get("/health")
async def health_check():
    """健康检查"""
    return {"status": "healthy", "service": "lambdalinker"}


import hashlib

def compute_content_hash(content_bytes: bytes) -> str:
    """计算内容的MD5哈希"""
    return hashlib.md5(content_bytes).hexdigest()

@app.post("/compare", response_model=CompareResponse)
async def compare_documents(request: Request):
    """对比两个文档 (兼容模式：支持 JSON 路径传递、Multipart 文件上传、以及 JSON Base64 文件内容)"""
    
    content_type = request.headers.get("content-type", "")
    
    file_a_path = None
    file_b_path = None
    doc_type = "word"
    use_cache = True
    use_mcp = True
    commit_a = None
    commit_b = None
    
    tmp_dir = None
    
    # 用于缓存键的内容哈希
    hash_a = None
    hash_b = None

    try:
        # 模式 1: Multipart 文件上传
        if "multipart/form-data" in content_type:
            logger.info("收到对比请求 (模式: Multipart Upload)")
            form = await request.form()
            
            # 提取字段
            doc_type = form.get("doc_type", "word")
            use_cache = str(form.get("use_cache", "true")).lower() == "true"
            use_mcp = str(form.get("use_mcp", "true")).lower() == "true"
            commit_a = form.get("commit_a")
            commit_b = form.get("commit_b")
            
            file_a = form.get("file_a")
            file_b = form.get("file_b")
            
            if not isinstance(file_a, UploadFile) or not isinstance(file_b, UploadFile):
                raise HTTPException(status_code=400, detail="Multipart 请求必须包含 file_a 和 file_b 文件")

            # 读取内容以计算哈希（如果需要）
            content_a = await file_a.read()
            content_b = await file_b.read()
            hash_a = compute_content_hash(content_a)
            hash_b = compute_content_hash(content_b)

            # 创建临时目录保存文件
            tmp_dir = Path(tempfile.mkdtemp())
            file_a_path = tmp_dir / (file_a.filename or "doc_a.docx")
            file_b_path = tmp_dir / (file_b.filename or "doc_b.docx")
            
            # 保存文件流
            with open(file_a_path, "wb") as buffer:
                buffer.write(content_a)
                
            with open(file_b_path, "wb") as buffer:
                buffer.write(content_b)

        # 模式 2 & 3: JSON 请求
        else:
            try:
                body = await request.json()
            except Exception as e:
                raise HTTPException(status_code=400, detail=f"无效的 JSON 请求体: {str(e)}")

            doc_type = body.get("doc_type", "word")
            use_cache = body.get("use_cache", True)
            use_mcp = body.get("use_mcp", True)
            commit_a = body.get("commit_a")
            commit_b = body.get("commit_b")

            file_a_str = body.get("file_a")
            file_b_str = body.get("file_b")
            
            file_a_base64 = body.get("file_a_base64")
            file_b_base64 = body.get("file_b_base64")

            # 模式 2: Base64 内容传递 (新兼容模式)
            if file_a_base64 and file_b_base64:
                logger.info("收到对比请求 (模式: JSON Base64)")
                tmp_dir = Path(tempfile.mkdtemp())
                
                # 解码内容
                try:
                    content_a = base64.b64decode(file_a_base64)
                    content_b = base64.b64decode(file_b_base64)
                    hash_a = compute_content_hash(content_a)
                    hash_b = compute_content_hash(content_b)
                except Exception as e:
                     raise HTTPException(status_code=400, detail=f"Base64 解码失败: {str(e)}")
                
                # 使用传入的文件名（如果有），否则用默认名
                name_a = Path(file_a_str).name if file_a_str else "doc_a.docx"
                name_b = Path(file_b_str).name if file_b_str else "doc_b.docx"
                
                file_a_path = tmp_dir / name_a
                file_b_path = tmp_dir / name_b
                
                with open(file_a_path, "wb") as f:
                    f.write(content_a)
                with open(file_b_path, "wb") as f:
                    f.write(content_b)

            # 模式 3: 本地路径传递 (旧兼容模式)
            else:
                logger.info("收到对比请求 (模式: JSON Path)")
                # 兼容 CompareRequest 模型验证
                if not file_a_str or not file_b_str:
                     raise HTTPException(status_code=400, detail="JSON 请求必须包含 file_a 和 file_b")

                file_a_path = Path(file_a_str)
                file_b_path = Path(file_b_str)

                # 验证本地文件存在
                if not file_a_path.exists():
                    raise HTTPException(status_code=404, detail=f"文件不存在: {file_a_str}")
                if not file_b_path.exists():
                    raise HTTPException(status_code=404, detail=f"文件不存在: {file_b_str}")

        # === 通用对比逻辑 ===
        logger.info(f"开始处理: {doc_type}, A={file_a_path}, B={file_b_path}")

        # 获取 LLM Agent
        llm_agent = default_agent_from_env()

        # 记录是否使用了缓存
        from core.cache_manager import get_cache_manager, compute_pair_key
        cached = False
        result = None

        # 如果启用缓存，先尝试获取缓存结果
        if use_cache:
            # 优先使用内容哈希作为缓存键的一部分（如果有），否则回退到 commit ID 或文件路径
            # 这里的 compute_pair_key 需要能够处理 hash 参数，或者我们构造一个特殊的 key
            # 为了不破坏现有逻辑，我们可以将 hash 作为 commit_a/b 传递（如果没有 commit ID）
            
            key_part_a = commit_a if commit_a else (hash_a if hash_a else str(file_a_path))
            key_part_b = commit_b if commit_b else (hash_b if hash_b else str(file_b_path))
            
            cache_key = compute_pair_key(str(file_a_path), str(file_b_path), doc_type, key_part_a, key_part_b)
            
            cached_result = get_cache_manager().get(cache_key)
            if cached_result is not None:
                cached = True
                result = cached_result
                logger.info(f"✅ 缓存命中: {cache_key}")

        # 如果没有缓存，执行LLM对比
        if result is None:
            if doc_type == "word":
                result = compare_word_docs(
                    str(file_a_path),
                    str(file_b_path),
                    llm_agent,
                    use_mcp=use_mcp,
                    use_cache=False,  # 禁用内部缓存
                )
            elif doc_type == "ppt":
                result = compare_ppt_decks(
                    str(file_a_path),
                    str(file_b_path),
                    llm_agent,
                    use_mcp=use_mcp,
                    use_cache=False,  # 禁用内部缓存
                )
            elif doc_type == "excel":
                result = compare_excel_docs(
                    str(file_a_path),
                    str(file_b_path),
                    llm_agent,
                    use_mcp=use_mcp,
                    use_cache=False,  # 禁用内部缓存
                )
            else:
                raise HTTPException(status_code=400, detail=f"不支持的文档类型: {doc_type}")

            # 保存结果到缓存
            if use_cache:
                 key_part_a = commit_a if commit_a else (hash_a if hash_a else str(file_a_path))
                 key_part_b = commit_b if commit_b else (hash_b if hash_b else str(file_b_path))
                 cache_key = compute_pair_key(str(file_a_path), str(file_b_path), doc_type, key_part_a, key_part_b)
                 
                 get_cache_manager().set(cache_key, result)
                 logger.info(f"✅ 缓存已保存: {cache_key}")

        logger.info(f"对比完成: {'使用缓存' if cached else '调用LLM'}")
        
        return CompareResponse(
            success=True,
            doc_type=doc_type,
            cached=cached,
            result=result
        )
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"对比失败: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        # 仅在 Multipart 模式下清理临时文件
        if tmp_dir and os.path.exists(tmp_dir):
            try:
                shutil.rmtree(tmp_dir, ignore_errors=True)
            except Exception as e:
                logger.error(f"清理临时文件失败: {e}")


@app.get("/cache/stats", response_model=CacheStatsResponse)
async def get_cache_stats():
    """获取缓存统计信息"""
    try:
        cache_mgr = get_cache_manager()
        stats = cache_mgr.get_cache_stats()
        
        return CacheStatsResponse(
            enabled=stats.get("enabled", False),
            cache_dir=stats.get("cache_dir", ""),
            total_entries=stats.get("total_entries", 0),
            total_size_mb=stats.get("total_size_mb", 0.0),
            max_entries=stats.get("max_entries", 0),
            max_size_mb=stats.get("max_size_mb", 0),
        )
    except Exception as e:
        logger.error(f"获取缓存统计失败: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/cache")
async def clear_cache():
    """清空所有缓存"""
    try:
        cache_mgr = get_cache_manager()
        deleted = cache_mgr.clear_all()
        
        logger.info(f"清空缓存: 删除 {deleted} 个条目")
        
        return {
            "success": True,
            "deleted": deleted,
            "message": f"已删除 {deleted} 个缓存条目"
        }
    except Exception as e:
        logger.error(f"清空缓存失败: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/cache/check")
async def check_cache(file_a: str, file_b: str, doc_type: str):
    """检查缓存是否存在"""
    try:
        from core.cache_manager import compute_pair_key
        
        cache_mgr = get_cache_manager()
        cache_key = compute_pair_key(file_a, file_b, doc_type)
        exists = cache_mgr.has(cache_key)
        
        return {
            "exists": exists,
            "cache_key": cache_key,
            "file_a": file_a,
            "file_b": file_b,
            "doc_type": doc_type
        }
    except Exception as e:
        logger.error(f"检查缓存失败: {e}")
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn
    
    logger.info("=" * 60)
    logger.info("启动 LambdaLinker API 服务器")
    logger.info("=" * 60)
    logger.info(f"项目根目录: {project_root}")
    logger.info(f"缓存目录: {get_cache_manager().config.cache_dir}")
    logger.info("API 文档: http://127.0.0.1:8765/docs")
    logger.info("=" * 60)
    
    uvicorn.run(
        app,
        host="127.0.0.1",
        port=8765,
        log_level="info"
    )

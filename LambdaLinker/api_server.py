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

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from dotenv import load_dotenv

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


@app.post("/compare", response_model=CompareResponse)
async def compare_documents(req: CompareRequest):
    """对比两个文档
    
    Args:
        req: 对比请求
        
    Returns:
        对比结果
    """
    logger.info(f"收到对比请求: {req.doc_type}, A={Path(req.file_a).name}, B={Path(req.file_b).name}, cache={req.use_cache}")
    
    # 验证文件存在
    file_a = Path(req.file_a)
    file_b = Path(req.file_b)
    
    if not file_a.exists():
        logger.error(f"文件不存在: {req.file_a}")
        raise HTTPException(status_code=404, detail=f"文件不存在: {req.file_a}")
    
    if not file_b.exists():
        logger.error(f"文件不存在: {req.file_b}")
        raise HTTPException(status_code=404, detail=f"文件不存在: {req.file_b}")
    
    try:
        # 获取 LLM Agent
        llm_agent = default_agent_from_env()
        
        # 记录是否使用了缓存
        from core.cache_manager import get_cached_result
        cached = False
        if req.use_cache:
            cached_result = get_cached_result(req.file_a, req.file_b, req.doc_type)
            if cached_result is not None:
                cached = True
        
        # 执行对比
        if req.doc_type == "word":
            result = compare_word_docs(
                str(file_a),
                str(file_b),
                llm_agent,
                use_mcp=req.use_mcp,
                use_cache=req.use_cache,
            )
        elif req.doc_type == "ppt":
            result = compare_ppt_decks(
                str(file_a),
                str(file_b),
                llm_agent,
                use_mcp=req.use_mcp,
                use_cache=req.use_cache,
            )
        elif req.doc_type == "excel":
            result = compare_excel_docs(
                str(file_a),
                str(file_b),
                llm_agent,
                use_mcp=req.use_mcp,
                use_cache=req.use_cache,
            )
        else:
            logger.error(f"不支持的文档类型: {req.doc_type}")
            raise HTTPException(status_code=400, detail=f"不支持的文档类型: {req.doc_type}")
        
        logger.info(f"对比完成: {'使用缓存' if cached else '调用LLM'}")
        
        return CompareResponse(
            success=True,
            doc_type=req.doc_type,
            cached=cached,
            result=result
        )
        
    except Exception as e:
        logger.error(f"对比失败: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


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

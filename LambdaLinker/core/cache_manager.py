"""AI 差异对比缓存管理器

功能：
1. 基于文件哈希的缓存存储
2. 避免重复调用 LLM
3. 支持缓存失效和清理
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)


@dataclass
class CacheConfig:
    """缓存配置"""
    cache_dir: Path = field(default_factory=lambda: _default_cache_dir())
    max_cache_size_mb: int = 500  # 最大缓存大小（MB）
    max_cache_entries: int = 1000  # 最大缓存条目数
    enabled: bool = True  # 是否启用缓存
    
    @staticmethod
    def from_env() -> "CacheConfig":
        """从环境变量读取配置"""
        cache_dir_str = os.getenv("LAMBDALINKER_CACHE_DIR", "").strip()
        cache_dir = Path(cache_dir_str) if cache_dir_str else _default_cache_dir()
        
        enabled = os.getenv("LAMBDALINKER_CACHE_ENABLED", "1").strip() not in ("0", "false", "no")
        max_size = int(os.getenv("LAMBDALINKER_CACHE_MAX_SIZE_MB", "500"))
        max_entries = int(os.getenv("LAMBDALINKER_CACHE_MAX_ENTRIES", "1000"))
        
        return CacheConfig(
            cache_dir=cache_dir,
            max_cache_size_mb=max_size,
            max_cache_entries=max_entries,
            enabled=enabled,
        )


def _default_cache_dir() -> Path:
    """获取默认缓存目录"""
    # Windows: AppData/LambdaLinker_cache
    # Linux/Mac: ~/.cache/LambdaLinker
    if os.name == 'nt':  # Windows
        appdata = os.getenv('APPDATA')
        if appdata:
            return Path(appdata) / "LambdaLinker_cache"
    
    # Linux/Mac
    cache_home = os.getenv('XDG_CACHE_HOME')
    if cache_home:
        return Path(cache_home) / "LambdaLinker"
    
    home = Path.home()
    return home / ".cache" / "LambdaLinker"


def compute_file_hash(file_path: str, algorithm: str = "sha256") -> str:
    """计算文件哈希值
    
    Args:
        file_path: 文件路径
        algorithm: 哈希算法 (md5, sha1, sha256)
        
    Returns:
        文件哈希值（十六进制字符串）
    """
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"文件不存在: {file_path}")
    
    hasher = hashlib.new(algorithm)
    
    # 分块读取文件，避免内存溢出
    with open(file_path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b""):
            hasher.update(chunk)
    
    return hasher.hexdigest()


def compute_pair_key(file_a_path: str, file_b_path: str, doc_type: str = "word") -> str:
    """计算文件对的缓存键
    
    Args:
        file_a_path: 文件A路径
        file_b_path: 文件B路径
        doc_type: 文档类型 (word, ppt, excel)
        
    Returns:
        缓存键字符串
    """
    hash_a = compute_file_hash(file_a_path)
    hash_b = compute_file_hash(file_b_path)
    
    # 格式：doctype_hashA_vs_hashB
    return f"{doc_type}_{hash_a}_vs_{hash_b}"


class CacheManager:
    """AI 差异对比缓存管理器"""
    
    def __init__(self, config: Optional[CacheConfig] = None):
        self.config = config or CacheConfig.from_env()
        self._ensure_cache_dir()
    
    def _ensure_cache_dir(self):
        """确保缓存目录存在"""
        if self.config.enabled:
            self.config.cache_dir.mkdir(parents=True, exist_ok=True)
            logger.info(f"缓存目录: {self.config.cache_dir}")
    
    def _get_cache_path(self, cache_key: str) -> Path:
        """获取缓存文件路径"""
        return self.config.cache_dir / f"{cache_key}.json"
    
    def get(self, cache_key: str) -> Optional[dict[str, Any]]:
        """读取缓存
        
        Args:
            cache_key: 缓存键
            
        Returns:
            缓存的结果字典，如果不存在则返回 None
        """
        if not self.config.enabled:
            return None
        
        cache_path = self._get_cache_path(cache_key)
        
        if not cache_path.exists():
            logger.debug(f"缓存未命中: {cache_key}")
            return None
        
        try:
            with open(cache_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
            
            logger.info(f"✅ 缓存命中: {cache_key}")
            return data
        except Exception as e:
            logger.warning(f"读取缓存失败: {cache_key}, 错误: {e}")
            return None
    
    def set(self, cache_key: str, result: dict[str, Any]) -> bool:
        """保存缓存
        
        Args:
            cache_key: 缓存键
            result: 要缓存的结果
            
        Returns:
            是否保存成功
        """
        if not self.config.enabled:
            return False
        
        cache_path = self._get_cache_path(cache_key)
        
        try:
            # 确保目录存在
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            
            # 保存缓存
            with open(cache_path, 'w', encoding='utf-8') as f:
                json.dump(result, f, ensure_ascii=False, indent=2)
            
            logger.info(f"✅ 缓存已保存: {cache_key}")
            
            # 检查并清理缓存
            self._cleanup_if_needed()
            
            return True
        except Exception as e:
            logger.error(f"保存缓存失败: {cache_key}, 错误: {e}")
            return False
    
    def has(self, cache_key: str) -> bool:
        """检查缓存是否存在"""
        if not self.config.enabled:
            return False
        return self._get_cache_path(cache_key).exists()
    
    def delete(self, cache_key: str) -> bool:
        """删除指定缓存"""
        if not self.config.enabled:
            return False
        
        cache_path = self._get_cache_path(cache_key)
        
        try:
            if cache_path.exists():
                cache_path.unlink()
                logger.info(f"删除缓存: {cache_key}")
                return True
        except Exception as e:
            logger.error(f"删除缓存失败: {cache_key}, 错误: {e}")
        
        return False
    
    def clear_all(self) -> int:
        """清空所有缓存
        
        Returns:
            删除的缓存条目数
        """
        if not self.config.enabled:
            return 0
        
        count = 0
        try:
            for cache_file in self.config.cache_dir.glob("*.json"):
                cache_file.unlink()
                count += 1
            logger.info(f"清空所有缓存，共删除 {count} 个文件")
        except Exception as e:
            logger.error(f"清空缓存失败: {e}")
        
        return count
    
    def get_cache_stats(self) -> dict[str, Any]:
        """获取缓存统计信息"""
        if not self.config.enabled:
            return {"enabled": False}
        
        try:
            cache_files = list(self.config.cache_dir.glob("*.json"))
            total_size = sum(f.stat().st_size for f in cache_files)
            
            return {
                "enabled": True,
                "cache_dir": str(self.config.cache_dir),
                "total_entries": len(cache_files),
                "total_size_mb": round(total_size / (1024 * 1024), 2),
                "max_size_mb": self.config.max_cache_size_mb,
                "max_entries": self.config.max_cache_entries,
            }
        except Exception as e:
            logger.error(f"获取缓存统计失败: {e}")
            return {"enabled": True, "error": str(e)}
    
    def _cleanup_if_needed(self):
        """检查并清理缓存（如果超过限制）"""
        try:
            cache_files = sorted(
                self.config.cache_dir.glob("*.json"),
                key=lambda f: f.stat().st_mtime,  # 按修改时间排序
            )
            
            # 检查条目数
            if len(cache_files) > self.config.max_cache_entries:
                # 删除最旧的缓存
                to_delete = len(cache_files) - self.config.max_cache_entries
                for old_file in cache_files[:to_delete]:
                    old_file.unlink()
                    logger.debug(f"清理旧缓存: {old_file.name}")
            
            # 检查总大小
            total_size = sum(f.stat().st_size for f in self.config.cache_dir.glob("*.json"))
            max_size_bytes = self.config.max_cache_size_mb * 1024 * 1024
            
            if total_size > max_size_bytes:
                # 按时间顺序删除，直到低于限制
                for old_file in cache_files:
                    old_file.unlink()
                    total_size -= old_file.stat().st_size
                    logger.debug(f"清理缓存（超大小）: {old_file.name}")
                    if total_size <= max_size_bytes:
                        break
        except Exception as e:
            logger.warning(f"清理缓存失败: {e}")


# 全局缓存管理器实例
_global_cache_manager: Optional[CacheManager] = None


def get_cache_manager() -> CacheManager:
    """获取全局缓存管理器实例"""
    global _global_cache_manager
    if _global_cache_manager is None:
        _global_cache_manager = CacheManager()
    return _global_cache_manager


def get_cached_result(
    file_a_path: str,
    file_b_path: str,
    doc_type: str = "word"
) -> Optional[dict[str, Any]]:
    """获取缓存的对比结果（便捷函数）
    
    Args:
        file_a_path: 文件A路径
        file_b_path: 文件B路径
        doc_type: 文档类型
        
    Returns:
        缓存的结果，如果不存在则返回 None
    """
    cache_key = compute_pair_key(file_a_path, file_b_path, doc_type)
    return get_cache_manager().get(cache_key)


def save_cached_result(
    file_a_path: str,
    file_b_path: str,
    result: dict[str, Any],
    doc_type: str = "word"
) -> bool:
    """保存对比结果到缓存（便捷函数）
    
    Args:
        file_a_path: 文件A路径
        file_b_path: 文件B路径
        result: 对比结果
        doc_type: 文档类型
        
    Returns:
        是否保存成功
    """
    cache_key = compute_pair_key(file_a_path, file_b_path, doc_type)
    return get_cache_manager().set(cache_key, result)

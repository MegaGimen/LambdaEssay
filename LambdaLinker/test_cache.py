#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""测试缓存功能

演示如何使用 AI 缓存来避免重复调用 LLM。
"""

import sys
import time
from pathlib import Path

# 添加项目根目录到 Python 路径
project_root = Path(__file__).parent
sys.path.insert(0, str(project_root))

# 加载 .env 文件
from dotenv import load_dotenv
env_path = project_root / ".env"
load_dotenv(env_path)

from core.lambdalinker import compare_word_docs
from core.agent import default_agent_from_env
from core.cache_manager import get_cache_manager


def test_cache_performance():
    """测试缓存性能提升"""
    print("=" * 60)
    print("测试 AI 缓存性能")
    print("=" * 60)
    
    llm_agent = default_agent_from_env()
    cache_mgr = get_cache_manager()
    
    # 获取缓存统计
    stats = cache_mgr.get_cache_stats()
    print(f"\n📊 缓存状态:")
    print(f"  - 启用: {stats.get('enabled')}")
    print(f"  - 缓存目录: {stats.get('cache_dir')}")
    print(f"  - 当前条目数: {stats.get('total_entries', 0)}")
    print(f"  - 缓存大小: {stats.get('total_size_mb', 0)} MB")
    
    doc_a = project_root / "examples/a.docx"
    doc_b = project_root / "examples/b.docx"
    
    # 第一次调用（无缓存）
    print("\n" + "=" * 60)
    print("第一次对比（无缓存，需要调用 LLM）")
    print("=" * 60)
    
    start_time = time.time()
    result1 = compare_word_docs(
        str(doc_a),
        str(doc_b),
        llm_agent,
        language="zh",
        use_mcp=False,  # 快速测试，不使用 MCP
        use_cache=True,  # 启用缓存
    )
    elapsed1 = time.time() - start_time
    
    print(f"⏱️  用时: {elapsed1:.2f} 秒")
    print(f"📝 摘要: {result1.get('summary', [])[:2]}")  # 只显示前2条
    
    # 第二次调用（使用缓存）
    print("\n" + "=" * 60)
    print("第二次对比（使用缓存，无需调用 LLM）")
    print("=" * 60)
    
    start_time = time.time()
    result2 = compare_word_docs(
        str(doc_a),
        str(doc_b),
        llm_agent,
        language="zh",
        use_mcp=False,
        use_cache=True,  # 启用缓存
    )
    elapsed2 = time.time() - start_time
    
    print(f"⏱️  用时: {elapsed2:.2f} 秒")
    print(f"📝 摘要: {result2.get('summary', [])[:2]}")
    
    # 性能对比
    print("\n" + "=" * 60)
    print("性能对比")
    print("=" * 60)
    print(f"第一次（无缓存）: {elapsed1:.2f} 秒")
    print(f"第二次（有缓存）: {elapsed2:.2f} 秒")
    print(f"速度提升: {elapsed1 / elapsed2:.1f}x")
    print(f"节省时间: {elapsed1 - elapsed2:.2f} 秒")
    
    # 验证结果一致性
    if result1.get('summary') == result2.get('summary'):
        print("\n✅ 缓存结果与原始结果一致")
    else:
        print("\n⚠️  警告：缓存结果与原始结果不一致")
    
    # 更新统计
    stats = cache_mgr.get_cache_stats()
    print(f"\n📊 缓存统计（更新后）:")
    print(f"  - 条目数: {stats.get('total_entries', 0)}")
    print(f"  - 缓存大小: {stats.get('total_size_mb', 0)} MB")


def test_cache_management():
    """测试缓存管理功能"""
    print("\n" + "=" * 60)
    print("测试缓存管理")
    print("=" * 60)
    
    cache_mgr = get_cache_manager()
    
    # 获取缓存统计
    stats = cache_mgr.get_cache_stats()
    print(f"\n当前缓存条目数: {stats.get('total_entries', 0)}")
    
    # 清空缓存
    print("\n清空所有缓存...")
    deleted = cache_mgr.clear_all()
    print(f"✅ 已删除 {deleted} 个缓存条目")
    
    # 验证清空
    stats = cache_mgr.get_cache_stats()
    print(f"清空后条目数: {stats.get('total_entries', 0)}")


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="测试缓存功能")
    parser.add_argument(
        "action",
        choices=["performance", "manage", "all"],
        help="测试类型: performance（性能测试）, manage（管理测试）, all（全部测试）",
    )
    
    args = parser.parse_args()
    
    try:
        if args.action == "performance":
            test_cache_performance()
        elif args.action == "manage":
            test_cache_management()
        elif args.action == "all":
            test_cache_performance()
            test_cache_management()
    except Exception as e:
        print(f"❌ 测试失败: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)

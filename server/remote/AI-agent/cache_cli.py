#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""缓存管理 CLI 工具

用于查看、清理、管理 LambdaLinker 的 AI 缓存。
"""

import argparse
import sys
from pathlib import Path

# 添加项目根目录到 Python 路径
project_root = Path(__file__).parent
sys.path.insert(0, str(project_root))

from core.cache_manager import get_cache_manager


def cmd_stats():
    """显示缓存统计信息"""
    cache_mgr = get_cache_manager()
    stats = cache_mgr.get_cache_stats()
    
    print("=" * 60)
    print("缓存统计信息")
    print("=" * 60)
    
    if not stats.get("enabled"):
        print("⚠️  缓存已禁用")
        return
    
    print(f"📁 缓存目录: {stats.get('cache_dir')}")
    print(f"📊 当前条目数: {stats.get('total_entries', 0)}")
    print(f"💾 缓存大小: {stats.get('total_size_mb', 0)} MB")
    print(f"📈 最大条目数: {stats.get('max_entries', 0)}")
    print(f"📈 最大大小: {stats.get('max_size_mb', 0)} MB")
    
    # 计算使用率
    total = stats.get('total_entries', 0)
    max_entries = stats.get('max_entries', 1)
    usage_percent = (total / max_entries * 100) if max_entries > 0 else 0
    print(f"📊 使用率: {usage_percent:.1f}%")


def cmd_list():
    """列出所有缓存条目"""
    cache_mgr = get_cache_manager()
    cache_dir = cache_mgr.config.cache_dir
    
    if not cache_dir.exists():
        print("缓存目录不存在")
        return
    
    cache_files = sorted(
        cache_dir.glob("*.json"),
        key=lambda f: f.stat().st_mtime,
        reverse=True,  # 最新的在前
    )
    
    if not cache_files:
        print("无缓存条目")
        return
    
    print("=" * 60)
    print(f"缓存条目列表（共 {len(cache_files)} 个）")
    print("=" * 60)
    
    from datetime import datetime
    
    for idx, cache_file in enumerate(cache_files, 1):
        size_kb = cache_file.stat().st_size / 1024
        mtime = datetime.fromtimestamp(cache_file.stat().st_mtime)
        
        # 解析文件名
        name = cache_file.stem
        parts = name.split("_")
        doc_type = parts[0] if len(parts) > 0 else "unknown"
        
        print(f"{idx}. {cache_file.name}")
        print(f"   类型: {doc_type.upper()}")
        print(f"   大小: {size_kb:.2f} KB")
        print(f"   修改时间: {mtime.strftime('%Y-%m-%d %H:%M:%S')}")
        print()


def cmd_clear(confirm: bool = False):
    """清空所有缓存"""
    cache_mgr = get_cache_manager()
    stats = cache_mgr.get_cache_stats()
    total = stats.get('total_entries', 0)
    
    if total == 0:
        print("缓存为空，无需清理")
        return
    
    if not confirm:
        print(f"⚠️  即将删除 {total} 个缓存条目")
        response = input("确认清空缓存？(yes/no): ")
        if response.lower() not in ('yes', 'y'):
            print("已取消")
            return
    
    deleted = cache_mgr.clear_all()
    print(f"✅ 已删除 {deleted} 个缓存条目")


def cmd_enable():
    """启用缓存"""
    import os
    print("提示：请在 .env 文件中设置 LAMBDALINKER_CACHE_ENABLED=1")
    print("或者设置环境变量：export LAMBDALINKER_CACHE_ENABLED=1")


def cmd_disable():
    """禁用缓存"""
    print("提示：请在 .env 文件中设置 LAMBDALINKER_CACHE_ENABLED=0")
    print("或者设置环境变量：export LAMBDALINKER_CACHE_ENABLED=0")


def main():
    parser = argparse.ArgumentParser(
        description="LambdaLinker 缓存管理工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    
    subparsers = parser.add_subparsers(dest="command", help="子命令")
    
    # stats 命令
    subparsers.add_parser("stats", help="显示缓存统计信息")
    
    # list 命令
    subparsers.add_parser("list", help="列出所有缓存条目")
    
    # clear 命令
    clear_parser = subparsers.add_parser("clear", help="清空所有缓存")
    clear_parser.add_argument(
        "-y", "--yes",
        action="store_true",
        help="跳过确认提示"
    )
    
    # enable/disable 命令
    subparsers.add_parser("enable", help="启用缓存")
    subparsers.add_parser("disable", help="禁用缓存")
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return
    
    try:
        if args.command == "stats":
            cmd_stats()
        elif args.command == "list":
            cmd_list()
        elif args.command == "clear":
            cmd_clear(confirm=args.yes)
        elif args.command == "enable":
            cmd_enable()
        elif args.command == "disable":
            cmd_disable()
    except Exception as e:
        print(f"❌ 错误: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()

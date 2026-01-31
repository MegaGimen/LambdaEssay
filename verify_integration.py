#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""验证 Dart 集成是否正确配置

测试 Python API 服务器和缓存功能。
"""

import sys
import time
from pathlib import Path

project_root = Path(__file__).parent
sys.path.insert(0, str(project_root))

import requests


def test_api_server():
    """测试 API 服务器"""
    print("=" * 60)
    print("测试 API 服务器")
    print("=" * 60)
    
    base_url = "http://127.0.0.1:8765"
    
    # 测试1: Health check
    print("\n1. 测试健康检查...")
    try:
        response = requests.get(f"{base_url}/health", timeout=5)
        if response.status_code == 200:
            print("   ✅ API 服务器运行正常")
            print(f"   响应: {response.json()}")
        else:
            print(f"   ❌ 健康检查失败: {response.status_code}")
            return False
    except requests.exceptions.ConnectionError:
        print("   ❌ 无法连接到 API 服务器")
        print("   请先运行: cd LambdaLinker && start_api.bat")
        return False
    except Exception as e:
        print(f"   ❌ 错误: {e}")
        return False
    
    # 测试2: 根路径
    print("\n2. 测试根路径...")
    try:
        response = requests.get(base_url, timeout=5)
        if response.status_code == 200:
            data = response.json()
            print("   ✅ API 信息:")
            print(f"   - 名称: {data.get('name')}")
            print(f"   - 版本: {data.get('version')}")
            print(f"   - 状态: {data.get('status')}")
        else:
            print(f"   ❌ 获取 API 信息失败: {response.status_code}")
    except Exception as e:
        print(f"   ❌ 错误: {e}")
    
    # 测试3: 缓存统计
    print("\n3. 测试缓存统计...")
    try:
        response = requests.get(f"{base_url}/cache/stats", timeout=5)
        if response.status_code == 200:
            stats = response.json()
            print("   ✅ 缓存统计:")
            print(f"   - 启用: {stats.get('enabled')}")
            print(f"   - 缓存目录: {stats.get('cache_dir')}")
            print(f"   - 条目数: {stats.get('total_entries')}")
            print(f"   - 大小: {stats.get('total_size_mb')} MB")
        else:
            print(f"   ❌ 获取缓存统计失败: {response.status_code}")
    except Exception as e:
        print(f"   ❌ 错误: {e}")
    
    # 测试4: API 文档
    print("\n4. API 文档地址:")
    print(f"   📖 {base_url}/docs")
    print(f"   📖 {base_url}/redoc")
    
    return True


def test_dart_integration():
    """测试 Dart 集成文件"""
    print("\n" + "=" * 60)
    print("检查 Dart 集成文件")
    print("=" * 60)
    
    files_to_check = [
        ("server/lib/ai_diff_service.dart", "AI 服务客户端"),
        ("server/lib/git_service.dart", "Git 服务（已添加 AI 对比）"),
        ("server/bin/server.dart", "服务器（已添加 AI 端点）"),
    ]
    
    all_exist = True
    for file_path, description in files_to_check:
        full_path = project_root.parent / file_path
        if full_path.exists():
            print(f"✅ {description}")
            print(f"   {file_path}")
        else:
            print(f"❌ {description} - 文件不存在")
            print(f"   {file_path}")
            all_exist = False
    
    return all_exist


def print_next_steps():
    """打印后续步骤"""
    print("\n" + "=" * 60)
    print("✅ 集成验证完成")
    print("=" * 60)
    print("\n📋 后续步骤:")
    print("\n1. 启动 Python API 服务器（如果还没启动）:")
    print("   cd LambdaLinker")
    print("   start_api.bat")
    print("\n2. 启动 Dart 服务器:")
    print("   cd server")
    print("   dart run bin/server.dart")
    print("\n3. 测试 AI 对比 API:")
    print("   curl -X POST http://localhost:8080/compare_ai \\")
    print("     -H \"Content-Type: application/json\" \\")
    print("     -d '{\"repoPath\":\"...\",\"commit1\":\"...\",\"commit2\":\"...\"}'")
    print("\n4. 查看缓存统计:")
    print("   curl http://localhost:8080/ai_cache/stats")
    print("\n📖 详细文档:")
    print("   - DART_INTEGRATION_GUIDE.md - Dart 集成指南")
    print("   - LambdaLinker/CACHE_GUIDE.md - 缓存使用指南")
    print("   - LambdaLinker/INTEGRATION_SUMMARY.md - 集成方案总结")


if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("Dart 集成验证脚本")
    print("=" * 60)
    
    # 检查 Dart 文件
    dart_ok = test_dart_integration()
    
    # 测试 API 服务器
    api_ok = test_api_server()
    
    # 打印后续步骤
    print_next_steps()
    
    # 总结
    print("\n" + "=" * 60)
    if dart_ok and api_ok:
        print("🎉 所有检查通过！集成成功！")
    elif dart_ok:
        print("⚠️  Dart 文件已就绪，但 API 服务器未运行")
        print("    请运行: cd LambdaLinker && start_api.bat")
    else:
        print("❌ 集成未完成，请检查文件")
    print("=" * 60)

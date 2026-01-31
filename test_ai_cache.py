"""AI 缓存功能自动化验证脚本（简化版）

这个脚本会：
1. 检查 Python API 服务是否运行
2. 使用已有的示例文档测试
3. 验证缓存是否生效
4. 测试 Dart 后端集成
"""

import os
import json
import time
import requests
from pathlib import Path

# 配置
PYTHON_API_URL = "http://127.0.0.1:8765"
DART_API_URL = "http://localhost:8080"
PROJECT_ROOT = Path(__file__).parent

def print_section(title):
    """打印分隔线"""
    print("\n" + "=" * 60)
    print(f"  {title}")
    print("=" * 60 + "\n")

def check_python_api():
    """检查 Python API 服务"""
    print_section("步骤 1: 检查 Python API 服务")
    
    try:
        resp = requests.get(f"{PYTHON_API_URL}/health", timeout=3)
        if resp.status_code == 200:
            data = resp.json()
            print(f"✅ Python API 服务正常运行")
            print(f"   状态: {data.get('status')}")
            print(f"   服务: {data.get('service')}")
            return True
    except requests.exceptions.ConnectionError:
        print("❌ Python API 服务未启动")
        print("\n请先启动服务:")
        print("   cd LambdaLinker")
        print("   venv\\Scripts\\activate")
        print("   python api_server.py")
        return False
    except Exception as e:
        print(f"❌ 检查服务时出错: {e}")
        return False

def find_test_documents():
    """查找测试文档"""
    print_section("步骤 2: 查找测试文档")
    
    # 查找 LambdaLinker 的示例文件
    examples_dir = PROJECT_ROOT / "LambdaLinker" / "examples"
    
    if not examples_dir.exists():
        print(f"❌ 示例目录不存在: {examples_dir}")
        return None, None
    
    # 尝试找 Word 文档
    docx_files = list(examples_dir.glob("*.docx"))
    
    if len(docx_files) < 2:
        # 尝试 Excel
        xlsx_files = list(examples_dir.glob("*.xlsx"))
        if len(xlsx_files) >= 2:
            print(f"✅ 找到 Excel 测试文档:")
            print(f"   文档 A: {xlsx_files[0].name}")
            print(f"   文档 B: {xlsx_files[1].name}")
            return str(xlsx_files[0]), str(xlsx_files[1]), "excel"
        
        # 尝试 PPT
        pptx_files = list(examples_dir.glob("*.pptx"))
        if len(pptx_files) >= 2:
            print(f"✅ 找到 PowerPoint 测试文档:")
            print(f"   文档 A: {pptx_files[0].name}")
            print(f"   文档 B: {pptx_files[1].name}")
            return str(pptx_files[0]), str(pptx_files[1]), "ppt"
        
        print("❌ 找不到测试文档（需要至少2个文档）")
        return None, None, None
    
    print(f"✅ 找到 Word 测试文档:")
    print(f"   文档 A: {docx_files[0].name}")
    if len(docx_files) > 1:
        print(f"   文档 B: {docx_files[1].name}")
        return str(docx_files[0]), str(docx_files[1]), "word"
    else:
        # 只有一个文档，复制一份
        print(f"   文档 B: {docx_files[0].name} (相同文档)")
        return str(docx_files[0]), str(docx_files[0]), "word"

def test_ai_compare_no_cache(doc_a, doc_b, doc_type):
    """测试 AI 对比（无缓存）"""
    print_section("步骤 3: 测试 AI 对比（第一次 - 无缓存）")
    
    payload = {
        "file_a": doc_a,
        "file_b": doc_b,
        "doc_type": doc_type,
        "use_cache": True,
        "use_mcp": False  # 暂时不使用 MCP，避免异步问题
    }
    
    print("📤 发送请求到 Python API...")
    print(f"   文档 A: {Path(doc_a).name}")
    print(f"   文档 B: {Path(doc_b).name}")
    print(f"   类型: {doc_type}")
    print(f"   使用 MCP: 否（使用 python-docx 直接读取）")
    
    start_time = time.time()
    
    try:
        resp = requests.post(
            f"{PYTHON_API_URL}/compare",
            json=payload,
            timeout=90
        )
        
        elapsed = time.time() - start_time
        
        if resp.status_code == 200:
            result = resp.json()
            print(f"\n✅ 对比成功！")
            print(f"   ⏱️  耗时: {elapsed:.2f} 秒")
            print(f"\n📊 AI 分析结果:")
            
            summary = result.get('summary', 'N/A')
            if len(summary) > 150:
                summary = summary[:150] + "..."
            print(f"   摘要: {summary}")
            
            key_changes = result.get('key_changes', [])
            if key_changes:
                print(f"\n   关键变化 ({len(key_changes)} 项):")
                for i, change in enumerate(key_changes[:3], 1):
                    if len(change) > 80:
                        change = change[:80] + "..."
                    print(f"      {i}. {change}")
            
            return elapsed, result
        else:
            print(f"❌ 请求失败: {resp.status_code}")
            print(f"   错误: {resp.text[:200]}")
            return None, None
            
    except requests.exceptions.Timeout:
        print("❌ 请求超时（LLM 服务可能较慢或未配置）")
        return None, None
    except Exception as e:
        print(f"❌ 请求出错: {e}")
        return None, None

def test_ai_compare_with_cache(doc_a, doc_b, doc_type):
    """测试 AI 对比（使用缓存）"""
    print_section("步骤 4: 测试 AI 对比（第二次 - 使用缓存）")
    
    payload = {
        "file_a": doc_a,
        "file_b": doc_b,
        "doc_type": doc_type,
        "use_cache": True,
        "use_mcp": False  # 保持一致
    }
    
    print("📤 再次发送相同请求...")
    
    start_time = time.time()
    
    try:
        resp = requests.post(
            f"{PYTHON_API_URL}/compare",
            json=payload,
            timeout=10
        )
        
        elapsed = time.time() - start_time
        
        if resp.status_code == 200:
            result = resp.json()
            print(f"\n✅ 获取结果成功！")
            print(f"   ⏱️  耗时: {elapsed:.2f} 秒")
            
            if elapsed < 1.0:
                print(f"\n🎉 缓存生效！速度提升显著！")
                return elapsed, result
            else:
                print(f"\n⚠️  响应较慢，可能未使用缓存")
                return elapsed, result
        else:
            print(f"❌ 请求失败: {resp.status_code}")
            return None, None
            
    except Exception as e:
        print(f"❌ 请求出错: {e}")
        return None, None

def check_cache_stats():
    """检查缓存统计"""
    print_section("步骤 5: 检查缓存统计")
    
    try:
        resp = requests.get(f"{PYTHON_API_URL}/cache/stats", timeout=5)
        
        if resp.status_code == 200:
            stats = resp.json()
            print("✅ 缓存统计:")
            print(f"   启用状态: {'✅ 已启用' if stats.get('enabled') else '❌ 未启用'}")
            print(f"   缓存目录: {stats.get('cache_dir')}")
            print(f"   总条目数: {stats.get('total_entries', 0)}")
            print(f"   总大小: {stats.get('total_size_mb', 0):.2f} MB")
            print(f"   最大大小: {stats.get('max_size_mb', 0)} MB")
            print(f"   最大条目: {stats.get('max_entries', 0)}")
            
            return stats
        else:
            print(f"❌ 获取统计失败: {resp.status_code}")
            return None
            
    except Exception as e:
        print(f"❌ 获取统计出错: {e}")
        return None

def check_dart_backend():
    """检查 Dart 后端"""
    print_section("步骤 6: 检查 Dart 后端集成")
    
    try:
        resp = requests.get(f"{DART_API_URL}/ai_cache/stats", timeout=3)
        
        if resp.status_code == 200:
            stats = resp.json()
            print("✅ Dart 后端可以访问 Python AI 服务")
            print(f"   通过 Dart API 获取的缓存统计:")
            print(f"   总条目数: {stats.get('total_entries', 0)}")
            print(f"   缓存目录: {stats.get('cache_dir')}")
            return True
        else:
            print(f"⚠️  Dart 后端未启动或无法连接")
            print(f"   状态码: {resp.status_code}")
            return False
            
    except requests.exceptions.ConnectionError:
        print("⚠️  Dart 后端未启动")
        print("\n如需测试完整集成，请启动 Dart 服务:")
        print("   cd server")
        print("   dart run bin/server.dart")
        return False
    except Exception as e:
        print(f"⚠️  检查 Dart 后端时出错: {e}")
        return False

def generate_report(results):
    """生成测试报告"""
    print_section("测试报告")
    
    first_time = results.get('first_time')
    second_time = results.get('second_time')
    cache_stats = results.get('cache_stats')
    dart_ok = results.get('dart_ok', False)
    doc_type = results.get('doc_type', 'unknown')
    
    print("📊 验证结果总结:\n")
    
    # Python API 测试
    print("1. Python API 服务:")
    print("   ✅ 服务正常运行\n")
    
    # AI 对比测试
    if first_time and second_time:
        speedup = first_time / second_time if second_time > 0 else 0
        print("2. AI 对比功能:")
        print(f"   ✅ 第一次调用: {first_time:.2f} 秒 (无缓存，调用 LLM)")
        print(f"   ✅ 第二次调用: {second_time:.2f} 秒 (使用缓存)")
        print(f"   🚀 速度提升: {speedup:.1f}x")
        print(f"   📄 文档类型: {doc_type}\n")
        
        if second_time < 1.0:
            print("   🎉 缓存机制工作正常！\n")
        else:
            print("   ⚠️  缓存可能未生效，请检查配置\n")
    elif first_time:
        print("2. AI 对比功能:")
        print(f"   ⚠️  第一次测试完成，第二次未完成")
        print(f"   第一次耗时: {first_time:.2f} 秒\n")
    else:
        print("2. AI 对比功能:")
        print("   ❌ 测试未完成\n")
    
    # 缓存统计
    if cache_stats:
        print("3. 缓存系统:")
        print(f"   ✅ 已启用")
        print(f"   📁 缓存目录: {cache_stats.get('cache_dir')}")
        print(f"   📦 缓存条目: {cache_stats.get('total_entries', 0)}\n")
    else:
        print("3. 缓存系统:")
        print("   ❌ 无法获取统计信息\n")
    
    # Dart 集成
    print("4. Dart 后端集成:")
    if dart_ok:
        print("   ✅ Dart 可以正常调用 Python AI 服务\n")
    else:
        print("   ⚠️  未测试（Dart 服务未启动）\n")
    
    # 总结
    print("=" * 60)
    if first_time and second_time and second_time < 1.0:
        print("🎉 所有测试通过！AI 缓存机制工作正常！")
        print("\n核心功能验证:")
        print("  ✅ Python API 服务运行正常")
        print("  ✅ AI 文档对比功能正常")
        print("  ✅ 缓存机制有效（速度提升明显）")
        print(f"  ✅ 支持 {doc_type} 格式文档")
    elif first_time:
        print("⚠️  部分测试完成，缓存可能未生效")
        print("\n建议检查:")
        print("  - LLM API 配置是否正确 (.env 文件)")
        print("  - 缓存目录权限是否正常")
    else:
        print("❌ 测试未通过，请检查上述详细信息")
    print("=" * 60)

def main():
    """主函数"""
    print("\n" + "=" * 60)
    print("  AI 缓存功能自动化验证")
    print("=" * 60)
    
    results = {}
    
    # 1. 检查 Python API
    if not check_python_api():
        print("\n❌ 验证终止：请先启动 Python API 服务")
        return
    
    # 2. 查找测试文档
    docs = find_test_documents()
    if docs[0] is None or docs[1] is None:
        print("\n❌ 验证终止：找不到测试文档")
        print("\n请确保 LambdaLinker/examples/ 目录下有测试文档")
        return
    
    doc_a, doc_b, doc_type = docs
    results['doc_type'] = doc_type
    
    # 3. 第一次测试（无缓存）
    first_time, first_result = test_ai_compare_no_cache(doc_a, doc_b, doc_type)
    if first_time:
        results['first_time'] = first_time
        results['first_result'] = first_result
    else:
        print("\n⚠️  第一次测试失败，可能是:")
        print("   - LLM API Key 未配置（检查 LambdaLinker/.env）")
        print("   - 网络连接问题")
        print("   - 服务内部错误")
        print("\n继续执行后续测试...")
    
    # 4. 第二次测试（使用缓存）
    if first_time:
        time.sleep(1)  # 短暂等待
        second_time, second_result = test_ai_compare_with_cache(doc_a, doc_b, doc_type)
        if second_time:
            results['second_time'] = second_time
            results['second_result'] = second_result
    
    # 5. 检查缓存统计
    cache_stats = check_cache_stats()
    if cache_stats:
        results['cache_stats'] = cache_stats
    
    # 6. 检查 Dart 集成
    dart_ok = check_dart_backend()
    results['dart_ok'] = dart_ok
    
    # 7. 生成报告
    generate_report(results)
    
    print("\n")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n⚠️  用户中断")
    except Exception as e:
        print(f"\n\n❌ 发生错误: {e}")
        import traceback
        traceback.print_exc()

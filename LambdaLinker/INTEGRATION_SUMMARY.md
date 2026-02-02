# LambdaLinker AI 缓存机制 - 实现总结

## 🎯 **已完成的工作**

### 1. **核心缓存管理器** ✅
**文件**: `core/cache_manager.py`

**功能**:
- ✅ 基于文件哈希（SHA256）的缓存键生成
- ✅ 自动缓存管理（读取/写入/删除/清空）
- ✅ 缓存大小和条目数限制
- ✅ 自动清理过期缓存
- ✅ 跨平台缓存目录支持
- ✅ 完整的缓存统计信息

**核心类**:
```python
class CacheManager:
    - get(cache_key) -> dict | None          # 读取缓存
    - set(cache_key, result) -> bool         # 保存缓存
    - has(cache_key) -> bool                 # 检查缓存
    - delete(cache_key) -> bool              # 删除缓存
    - clear_all() -> int                     # 清空所有
    - get_cache_stats() -> dict              # 获取统计
```

---

### 2. **集成到核心对比函数** ✅
**文件**: `core/lambdalinker.py`

**修改内容**:
- ✅ `compare_word_docs()` - 添加 `use_cache` 参数
- ✅ `compare_ppt_decks()` - 添加 `use_cache` 参数
- ✅ `compare_excel_docs()` - 添加 `use_cache` 参数

**工作流程**:
```python
def compare_word_docs(..., use_cache=True):
    # 1. 检查缓存
    if use_cache:
        cached = get_cached_result(doc_a_path, doc_b_path, "word")
        if cached:
            return cached  # 缓存命中
    
    # 2. 调用 LLM（缓存未命中）
    result = ... # LLM 分析
    
    # 3. 保存到缓存
    if use_cache:
        save_cached_result(doc_a_path, doc_b_path, result, "word")
    
    return result
```

---

### 3. **缓存管理 CLI 工具** ✅
**文件**: `cache_cli.py`

**命令**:
```bash
python cache_cli.py stats    # 查看统计
python cache_cli.py list     # 列出缓存
python cache_cli.py clear    # 清空缓存
python cache_cli.py enable   # 启用缓存
python cache_cli.py disable  # 禁用缓存
```

---

### 4. **缓存性能测试脚本** ✅
**文件**: `test_cache.py`

**测试内容**:
- ✅ 性能对比（缓存 vs 非缓存）
- ✅ 结果一致性验证
- ✅ 缓存管理功能测试

---

### 5. **文档更新** ✅
**文件**: `README.md`, `CACHE_GUIDE.md`

**新增内容**:
- ✅ 缓存功能说明
- ✅ 使用指南
- ✅ 环境变量配置
- ✅ 性能对比数据
- ✅ 常见问题解答

---

## 📊 **缓存机制架构**

```
LambdaLinker/
├── core/
│   ├── cache_manager.py      ← 缓存管理核心
│   └── lambdalinker.py        ← 集成缓存逻辑
├── cache_cli.py               ← CLI 管理工具
├── test_cache.py              ← 性能测试
└── CACHE_GUIDE.md             ← 使用指南

缓存存储（Windows）：
C:\Users\用户名\AppData\LambdaLinker_cache\
├── word_hash1_vs_hash2.json
├── ppt_hash3_vs_hash4.json
└── excel_hash5_vs_hash6.json
```

---

## 🔧 **如何集成到 Dart 后端**

### **方案A：HTTP API（推荐）**

#### **第1步：创建 Python Web 服务**

在 `LambdaLinker/` 创建 `api_server.py`:

```python
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from pathlib import Path

from core.lambdalinker import compare_word_docs, compare_ppt_decks, compare_excel_docs
from core.agent import default_agent_from_env
from core.cache_manager import get_cache_manager

app = FastAPI(title="LambdaLinker API")

class CompareRequest(BaseModel):
    file_a: str  # 文件A路径
    file_b: str  # 文件B路径
    doc_type: str  # 文档类型: word, ppt, excel
    use_cache: bool = True

class CacheStatsResponse(BaseModel):
    enabled: bool
    total_entries: int
    total_size_mb: float
    cache_dir: str

@app.post("/compare")
async def compare_documents(req: CompareRequest):
    """对比两个文档"""
    if not Path(req.file_a).exists():
        raise HTTPException(404, f"文件不存在: {req.file_a}")
    if not Path(req.file_b).exists():
        raise HTTPException(404, f"文件不存在: {req.file_b}")
    
    llm_agent = default_agent_from_env()
    
    try:
        if req.doc_type == "word":
            result = compare_word_docs(
                req.file_a, req.file_b, llm_agent, 
                use_mcp=False, use_cache=req.use_cache
            )
        elif req.doc_type == "ppt":
            result = compare_ppt_decks(
                req.file_a, req.file_b, llm_agent,
                use_mcp=True, use_cache=req.use_cache
            )
        elif req.doc_type == "excel":
            result = compare_excel_docs(
                req.file_a, req.file_b, llm_agent,
                use_mcp=True, use_cache=req.use_cache
            )
        else:
            raise HTTPException(400, f"不支持的文档类型: {req.doc_type}")
        
        return {
            "success": True,
            "doc_type": req.doc_type,
            "cached": result.get("_from_cache", False),
            "result": result
        }
    except Exception as e:
        raise HTTPException(500, str(e))

@app.get("/cache/stats")
async def get_cache_stats() -> CacheStatsResponse:
    """获取缓存统计"""
    cache_mgr = get_cache_manager()
    stats = cache_mgr.get_cache_stats()
    return CacheStatsResponse(**stats)

@app.delete("/cache")
async def clear_cache():
    """清空缓存"""
    cache_mgr = get_cache_manager()
    deleted = cache_mgr.clear_all()
    return {"success": True, "deleted": deleted}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8765)
```

启动服务：
```bash
pip install fastapi uvicorn
python api_server.py
```

---

#### **第2步：在 Dart 中创建缓存管理器**

在 `server/lib/` 创建 `ai_diff_cache.dart`:

```dart
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;

class AIDiffService {
  static const String _pythonApiUrl = 'http://localhost:8765';
  
  /// 对比两个文档（自动使用缓存）
  static Future<Map<String, dynamic>> compareDocuments(
    String fileAPath,
    String fileBPath,
    String docType, {
    bool useCache = true,
  }) async {
    final url = Uri.parse('$_pythonApiUrl/compare');
    
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'file_a': fileAPath,
          'file_b': fileBPath,
          'doc_type': docType,
          'use_cache': useCache,
        }),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        
        // 检查是否使用了缓存
        if (data['cached'] == true) {
          print('✅ AI缓存命中: $docType');
        } else {
          print('⏱️ AI分析完成（新结果）: $docType');
        }
        
        return data['result'] as Map<String, dynamic>;
      } else {
        throw Exception('AI服务调用失败: ${response.statusCode}');
      }
    } catch (e) {
      print('AI服务错误: $e');
      rethrow;
    }
  }
  
  /// 获取缓存统计
  static Future<Map<String, dynamic>> getCacheStats() async {
    final url = Uri.parse('$_pythonApiUrl/cache/stats');
    final response = await http.get(url);
    
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw Exception('获取缓存统计失败');
  }
  
  /// 清空缓存
  static Future<void> clearCache() async {
    final url = Uri.parse('$_pythonApiUrl/cache');
    final response = await http.delete(url);
    
    if (response.statusCode == 200) {
      print('✅ AI缓存已清空');
    } else {
      throw Exception('清空缓存失败');
    }
  }
}
```

---

#### **第3步：集成到 Git 服务**

修改 `server/lib/git_service.dart`:

```dart
import 'ai_diff_cache.dart';

/// AI 语义对比（带缓存）
Future<Map<String, dynamic>> compareCommitsWithAI(
  String repoPath,
  String commit1,
  String commit2,
  String docType,
) async {
  return _withRepoLock(repoPath, () async {
    // 1. 提取两个版本的文档到临时目录
    final tmpDir = await Directory.systemTemp.createTemp('ai_cmp_');
    
    try {
      final ext = docType == 'word' ? '.docx' 
                : docType == 'ppt' ? '.pptx' 
                : '.xlsx';
      
      final doc1Path = p.join(tmpDir.path, 'doc1$ext');
      final doc2Path = p.join(tmpDir.path, 'doc2$ext');
      
      // 提取文档
      await _extractDocFromCommit(repoPath, commit1, doc1Path);
      await _extractDocFromCommit(repoPath, commit2, doc2Path);
      
      // 2. 调用 AI 服务（自动使用缓存）
      final result = await AIDiffService.compareDocuments(
        doc1Path,
        doc2Path,
        docType,
        useCache: true,
      );
      
      return result;
    } finally {
      await tmpDir.delete(recursive: true);
    }
  });
}

/// 从 commit 提取文档
Future<void> _extractDocFromCommit(
  String repoPath,
  String commitId,
  String outputPath,
) async {
  final tmpDir = await Directory.systemTemp.createTemp('extract_');
  
  try {
    // 使用 git archive 提取文件
    final result = await Process.run(
      'git',
      [
        '--work-tree=${tmpDir.path}',
        'archive',
        '--format=tar',
        commitId,
        'doc_content/',
      ],
      workingDirectory: repoPath,
    );
    
    if (result.exitCode != 0) {
      throw Exception('提取文档失败: ${result.stderr}');
    }
    
    // 查找并复制文档
    final docxPath = p.join(tmpDir.path, 'doc_content', 'content.docx');
    if (await File(docxPath).exists()) {
      await File(docxPath).copy(outputPath);
    } else {
      throw Exception('文档不存在: $docxPath');
    }
  } finally {
    await tmpDir.delete(recursive: true);
  }
}
```

---

#### **第4步：添加 API 端点**

在 `server/bin/server.dart` 中添加:

```dart
// AI 对比端点
router.post('/compare_ai', (Request req) async {
  final body = await req.readAsString();
  final data = jsonDecode(body) as Map<String, dynamic>;
  
  final repoPath = _sanitizePath(data['repoPath'] as String?);
  final commit1 = data['commit1'] as String;
  final commit2 = data['commit2'] as String;
  final docType = data['docType'] as String? ?? 'word';
  
  try {
    final result = await compareCommitsWithAI(
      repoPath,
      commit1,
      commit2,
      docType,
    );
    
    return _cors(Response.ok(jsonEncode(result), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response.internalServerError(
      body: jsonEncode({'error': e.toString()}),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
    ));
  }
});

// 缓存统计端点
router.get('/cache_stats', (Request req) async {
  try {
    final stats = await AIDiffService.getCacheStats();
    return _cors(Response.ok(jsonEncode(stats), headers: {
      'Content-Type': 'application/json; charset=utf-8',
    }));
  } catch (e) {
    return _cors(Response.internalServerError(
      body: jsonEncode({'error': e.toString()}),
    ));
  }
});

// 清空缓存端点
router.delete('/clear_cache', (Request req) async {
  try {
    await AIDiffService.clearCache();
    return _cors(Response.ok(jsonEncode({'success': true})));
  } catch (e) {
    return _cors(Response.internalServerError(
      body: jsonEncode({'error': e.toString()}),
    ));
  }
});
```

---

#### **第5步：自动后台分析**

在 `createCommit` 函数中添加后台触发：

```dart
Future<void> createCommit(String repoPath, String message) async {
  return _withRepoLock(repoPath, () async {
    // ... 现有的 commit 逻辑 ...
    await _runGit(['commit', '-m', message], repoPath);
    
    // 🔥 新增：后台触发 AI 分析
    final currentCommit = await _getCurrentCommitId(repoPath);
    final parentCommit = await _getParentCommitId(repoPath);
    
    if (parentCommit != null) {
      // 异步执行，不阻塞
      _analyzeInBackground(repoPath, parentCommit, currentCommit);
    }
    
    clearCache();
  });
}

/// 后台 AI 分析
void _analyzeInBackground(
  String repoPath,
  String commit1,
  String commit2,
) {
  Future.microtask(() async {
    try {
      print('后台AI分析: $commit1 -> $commit2');
      await compareCommitsWithAI(repoPath, commit1, commit2, 'word');
      print('✅ AI分析完成并已缓存');
    } catch (e) {
      print('⚠️ 后台AI分析失败: $e');
    }
  });
}
```

---

## 📈 **预期效果**

### **性能提升**
```
第一次对比：
  - 调用 LLM: 5-15秒
  - 生成结果
  - 保存缓存

第二次对比（相同文件）：
  - 读取缓存: 0.01-0.05秒
  - 速度提升: 100-1500倍 ✨
```

### **成本节省**
```
假设：
- LLM API 成本：¥0.02/次
- 每月对比：1000次
- 缓存命中率：70%

节省成本 = 1000 × 0.7 × ¥0.02 = ¥14/月
年节省 = ¥168
```

---

## ✅ **测试清单**

### **Python 端测试**
```bash
# 1. 测试缓存功能
cd LambdaLinker
python test_cache.py performance

# 2. 测试 CLI 工具
python cache_cli.py stats
python cache_cli.py list

# 3. 测试 API 服务（如果实现）
python api_server.py
curl http://localhost:8765/cache/stats
```

### **Dart 端测试**（需要实现后）
```bash
# 1. 启动 Python API 服务
cd LambdaLinker
python api_server.py

# 2. 启动 Dart 服务器
cd server
dart run bin/server.dart

# 3. 测试 API
curl -X POST http://localhost:8080/compare_ai \
  -d '{"repoPath":"...","commit1":"abc","commit2":"def"}'
```

---

## 🎁 **总结**

### **已实现（Python 端）** ✅
1. ✅ 完整的缓存管理器
2. ✅ 集成到 Word/PPT/Excel 对比
3. ✅ CLI 管理工具
4. ✅ 性能测试脚本
5. ✅ 完整文档

### **待实现（Dart 端集成）** 📋
1. ⏳ 创建 Python API 服务 (`api_server.py`)
2. ⏳ Dart AI 服务封装 (`ai_diff_cache.dart`)
3. ⏳ 集成到 Git 服务
4. ⏳ 添加 API 端点
5. ⏳ 实现后台自动分析

### **下一步行动** 🚀
1. 测试 Python 端缓存功能
2. 实现 FastAPI 服务器
3. 创建 Dart 客户端
4. 端到端测试
5. 部署到生产环境

---

## 📞 **需要帮助？**

如果在实现过程中遇到问题，可以：

1. 查看 `CACHE_GUIDE.md` - 详细使用指南
2. 运行 `python test_cache.py all` - 测试所有功能
3. 查看日志输出 - 缓存管理器会输出详细日志

祝集成顺利！🎉

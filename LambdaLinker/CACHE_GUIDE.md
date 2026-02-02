# AI 缓存机制使用指南

## 概述

LambdaLinker 的 AI 缓存机制通过缓存 LLM 对比结果，避免重复计算，显著提升性能和降低成本。

## 核心特性

### 🚀 **性能提升**
- **速度提升**: 100x+ (从数秒到毫秒)
- **成本节省**: 避免重复 API 调用
- **自动管理**: 自动清理过期缓存

### 🔑 **缓存策略**
- **基于文件哈希**: 使用 SHA256 算法计算文件唯一标识
- **智能检测**: 文件内容变化自动失效缓存
- **独立缓存**: Word/PPT/Excel 分别缓存

### 📁 **缓存位置**

**Windows:**
```
C:\Users\你的用户名\AppData\LambdaLinker_cache\
├── word_abc123...def456_vs_789012...ghi345.json
├── ppt_111222...333444_vs_555666...777888.json
└── excel_aaa111...bbb222_vs_ccc333...ddd444.json
```

**Linux/Mac:**
```
~/.cache/LambdaLinker/
└── (同上)
```

---

## 快速开始

### 1. 启用缓存（默认已启用）

在 `.env` 文件中：

```bash
# 启用缓存
LAMBDALINKER_CACHE_ENABLED=1

# 缓存配置（可选）
LAMBDALINKER_CACHE_MAX_SIZE_MB=500      # 最大500MB
LAMBDALINKER_CACHE_MAX_ENTRIES=1000     # 最多1000个条目
```

### 2. 使用缓存

```python
from core.lambdalinker import compare_word_docs
from core.agent import default_agent_from_env

llm_agent = default_agent_from_env()

# 第一次对比（调用 LLM）
result1 = compare_word_docs(
    "a.docx",
    "b.docx",
    llm_agent,
    use_cache=True,  # 启用缓存
)

# 第二次对比（使用缓存，速度快100倍+）
result2 = compare_word_docs(
    "a.docx",
    "b.docx",
    llm_agent,
    use_cache=True,
)
```

### 3. 管理缓存

```bash
# 查看缓存统计
python cache_cli.py stats

# 列出所有缓存
python cache_cli.py list

# 清空所有缓存
python cache_cli.py clear
```

---

## 详细使用

### 缓存工作原理

```
用户请求对比 a.docx vs b.docx
    ↓
1. 计算文件哈希
   - a.docx → hash_a = "abc123..."
   - b.docx → hash_b = "def456..."
    ↓
2. 生成缓存键
   - key = "word_abc123..._vs_def456..."
    ↓
3. 检查缓存
   - 缓存存在？
       ├─ 是 → 直接返回（毫秒级）✅
       └─ 否 ↓
    ↓
4. 调用 LLM 分析
   - 提取文档内容
   - 发送给 LLM
   - 解析结果
    ↓
5. 保存到缓存
   - 写入 JSON 文件
   - 更新统计信息
    ↓
6. 返回结果
```

### 缓存键生成规则

```python
# 格式：{doc_type}_{hash_a}_vs_{hash_b}

# Word 示例
"word_a1b2c3d4e5f6..._vs_f6e5d4c3b2a1..."

# PPT 示例  
"ppt_111222333444..._vs_555666777888..."

# Excel 示例
"excel_aaa111bbb222..._vs_ccc333ddd444..."
```

### 缓存命中条件

缓存命中需要满足：
1. ✅ 文件 A 的哈希值相同
2. ✅ 文件 B 的哈希值相同
3. ✅ 文档类型相同
4. ✅ 缓存文件存在且有效

---

## 缓存管理

### 查看缓存统计

```bash
$ python cache_cli.py stats

============================================================
缓存统计信息
============================================================
📁 缓存目录: C:\Users\Admin\AppData\LambdaLinker_cache
📊 当前条目数: 15
💾 缓存大小: 2.45 MB
📈 最大条目数: 1000
📈 最大大小: 500 MB
📊 使用率: 1.5%
```

### 列出所有缓存

```bash
$ python cache_cli.py list

============================================================
缓存条目列表（共 15 个）
============================================================
1. word_abc123...def456_vs_789012...ghi345.json
   类型: WORD
   大小: 156.42 KB
   修改时间: 2026-01-31 12:34:56

2. ppt_111222...333444_vs_555666...777888.json
   类型: PPT
   大小: 203.17 KB
   修改时间: 2026-01-31 11:22:33

...
```

### 清空缓存

```bash
$ python cache_cli.py clear

⚠️  即将删除 15 个缓存条目
确认清空缓存？(yes/no): yes
✅ 已删除 15 个缓存条目
```

强制清空（跳过确认）：

```bash
$ python cache_cli.py clear -y
```

### 禁用缓存

临时禁用（运行时）：

```python
result = compare_word_docs(
    "a.docx",
    "b.docx",
    llm_agent,
    use_cache=False,  # 禁用缓存
)
```

永久禁用（环境变量）：

```bash
# 在 .env 中设置
LAMBDALINKER_CACHE_ENABLED=0
```

---

## 性能测试

### 运行性能测试

```bash
python test_cache.py performance
```

### 测试结果示例

```
============================================================
第一次对比（无缓存，需要调用 LLM）
============================================================
⏱️  用时: 8.42 秒
📝 摘要: ['文档B删除了第3段内容', '新增了结论部分']

============================================================
第二次对比（使用缓存，无需调用 LLM）
============================================================
⏱️  用时: 0.05 秒
📝 摘要: ['文档B删除了第3段内容', '新增了结论部分']

============================================================
性能对比
============================================================
第一次（无缓存）: 8.42 秒
第二次（有缓存）: 0.05 秒
速度提升: 168.4x
节省时间: 8.37 秒

✅ 缓存结果与原始结果一致
```

---

## 高级配置

### 自定义缓存目录

```bash
# 在 .env 中设置
LAMBDALINKER_CACHE_DIR=/path/to/custom/cache
```

### 调整缓存大小限制

```bash
# 最大缓存大小（MB）
LAMBDALINKER_CACHE_MAX_SIZE_MB=1000

# 最大缓存条目数
LAMBDALINKER_CACHE_MAX_ENTRIES=2000
```

### 缓存清理策略

缓存管理器会自动清理：

1. **条目数超限**: 删除最旧的缓存
2. **大小超限**: 按时间顺序删除，直到低于限制

---

## 编程接口

### 直接使用缓存管理器

```python
from core.cache_manager import get_cache_manager, compute_pair_key

# 获取缓存管理器
cache_mgr = get_cache_manager()

# 生成缓存键
cache_key = compute_pair_key("a.docx", "b.docx", "word")

# 检查缓存是否存在
if cache_mgr.has(cache_key):
    print("缓存存在")

# 读取缓存
result = cache_mgr.get(cache_key)

# 保存缓存
cache_mgr.set(cache_key, {"summary": ["..."]})

# 删除缓存
cache_mgr.delete(cache_key)

# 清空所有缓存
cache_mgr.clear_all()

# 获取统计信息
stats = cache_mgr.get_cache_stats()
print(f"缓存条目数: {stats['total_entries']}")
```

### 便捷函数

```python
from core.cache_manager import get_cached_result, save_cached_result

# 获取缓存结果
cached = get_cached_result("a.docx", "b.docx", "word")

# 保存缓存结果
save_cached_result("a.docx", "b.docx", result, "word")
```

---

## 常见问题

### Q: 缓存何时失效？

A: 当任一文件内容变化时，哈希值改变，自动使用新缓存键（旧缓存不会自动删除，但不会被访问）。

### Q: 缓存会占用多少空间？

A: 每个缓存条目约 10-200 KB（JSON 文本），默认限制 500MB（约 2500-50000 个缓存）。

### Q: 如何手动删除特定缓存？

A: 
```python
from core.cache_manager import get_cache_manager, compute_pair_key

cache_mgr = get_cache_manager()
cache_key = compute_pair_key("a.docx", "b.docx", "word")
cache_mgr.delete(cache_key)
```

### Q: 缓存是否跨平台？

A: 是的，缓存文件是纯 JSON 格式，可以在不同平台间复制使用。

### Q: 如何备份缓存？

A: 直接复制缓存目录：
```bash
# Windows
xcopy C:\Users\你的用户名\AppData\LambdaLinker_cache D:\backup\ /E /I

# Linux/Mac
cp -r ~/.cache/LambdaLinker /path/to/backup/
```

---

## 最佳实践

### 1. 开发环境
- ✅ 启用缓存，提升开发效率
- ✅ 定期清理过期缓存

### 2. 生产环境
- ✅ 启用缓存，降低 API 成本
- ✅ 监控缓存命中率
- ✅ 定期备份缓存

### 3. CI/CD
- ⚠️  可能需要禁用缓存，确保每次测试都调用 LLM
- 或在测试前清空缓存：`python cache_cli.py clear -y`

### 4. 多用户环境
- 每个用户有独立的缓存目录
- 可以考虑共享缓存目录（需要权限配置）

---

## 故障排查

### 缓存未生效

1. 检查缓存是否启用：
   ```bash
   python cache_cli.py stats
   ```

2. 检查环境变量：
   ```bash
   echo $LAMBDALINKER_CACHE_ENABLED
   ```

3. 检查函数参数：
   ```python
   result = compare_word_docs(..., use_cache=True)
   ```

### 缓存目录权限问题

```bash
# Windows - 确保有写入权限
icacls C:\Users\你的用户名\AppData\LambdaLinker_cache

# Linux/Mac - 设置权限
chmod 755 ~/.cache/LambdaLinker
```

### 缓存大小异常

```bash
# 查看缓存统计
python cache_cli.py stats

# 清空缓存
python cache_cli.py clear -y
```

---

## 总结

AI 缓存机制是 LambdaLinker 的核心功能之一，通过智能缓存策略：

- ✅ **性能提升 100倍+**
- ✅ **降低 API 成本**
- ✅ **自动管理，零配置**
- ✅ **灵活可控**

建议在日常使用中保持缓存启用，享受极速体验！🚀

# ✅ MCP 配置问题修复报告

## ❌ **问题**

### **错误信息**
```
RuntimeError: Client failed to connect: [WinError 2] 系统找不到指定的文件。
```
和
```
RuntimeError: asyncio.run() cannot be called from a running event loop
```

---

## 🔍 **问题分析**

### **主要问题**

**MCP Word Server 配置错误**：

检查 `LambdaLinker/mcp-config.json`:
```json
{
  "mcpServers": {
    "markitdown": {
      "command": "D:/helloagent/.venv/Scripts/python.exe",  ❌ 别人的电脑路径
      "args": [
        "D:/helloagent/LambdaEssay-new/LambdaLinker/mcp_modules/markitdown_mcp_server.py"  ❌ 不存在
      ]
    }
  }
}
```

这个配置文件指向了**别人电脑**的路径，导致：
1. Python找不到MCP服务器文件
2. 启动MCP Server失败
3. 触发一系列异步错误

### **什么是 MCP？**

**MCP (Model Context Protocol)** 是一个可选的增强功能，用于：
- 更智能地提取Word文档内容
- 支持图片识别和描述
- **但不是必需的！**

---

## 🔧 **修复方案**

### **采用方案：暂时禁用MCP**

因为：
1. ✅ MCP **不是必需**的功能
2. ✅ 不使用MCP，AI对比**照样可以工作**
3. ✅ 避免复杂的MCP服务器配置
4. ✅ 快速解决问题

---

## 📝 **修改内容**

### **文件1: `LambdaLinker/.env`**

```env
# 修改前
USE_MCP=1

# 修改后
USE_MCP=0  ✅ 禁用MCP
```

### **文件2: `server/lib/git_service.dart`**

```dart
// 修改前
final result = await AIDiffService.compareDocuments(
  doc1Path,
  doc2Path,
  'word',
  useCache: true,
  useMcp: true,  ❌
);

// 修改后
final result = await AIDiffService.compareDocuments(
  doc1Path,
  doc2Path,
  'word',
  useCache: true,
  useMcp: false,  ✅ 禁用MCP
);
```

---

## 🚀 **重启服务**

### **1. 重启Python AI服务**
修改了`.env`，必须重启Python服务才能生效。

### **2. 重启Dart后端**
修改了Dart代码，必须重启后端。

---

## ✅ **预期效果**

### **禁用MCP后**

#### **不影响**：
- ✅ AI对比功能照常工作
- ✅ Word/PPT/Excel文档对比正常
- ✅ 缓存机制照常运行
- ✅ 前端显示AI分析结果

#### **唯一影响**：
- ⚠️ Word文档提取时，**不会**识别图片内容
- ⚠️ 但大多数场景下，文字内容已经足够

---

## 🎯 **下一步**

### **立即执行**

1. **重启Python AI服务**（必须）
2. **重启Dart后端**（必须）
3. **测试AI对比**

### **如果你想启用MCP**（可选）

修复 `mcp-config.json` 中的路径：

```json
{
  "mcpServers": {
    "markitdown": {
      "command": "E:\\lambaessay_project\\LambdaEssay\\LambdaLinker\\venv\\Scripts\\python.exe",
      "args": [
        "E:\\lambaessay_project\\LambdaEssay\\LambdaLinker\\mcp_modules\\markitdown_mcp_server.py"
      ]
    }
  }
}
```

然后：
1. 修改 `.env` 中 `USE_MCP=1`
2. 修改 `git_service.dart` 中 `useMcp: true`
3. 重启所有服务

---

## 📊 **技术说明**

### **为什么MCP会导致事件循环错误？**

**流程**：
```
FastAPI接收请求 → 已有事件循环
  ↓
  调用compare_word_docs(use_mcp=true)
  ↓
  read_docx_paragraphs 尝试启动MCP Server
  ↓
  ❌ MCP配置路径错误 → FileNotFoundError
  ↓
  错误处理 → 尝试重试
  ↓
  在except块中调用 asyncio.run()
  ↓
  ❌ 与FastAPI的事件循环冲突
```

**禁用MCP后**：
```
FastAPI接收请求
  ↓
  调用compare_word_docs(use_mcp=false)
  ↓
  直接使用 python-docx 提取文档
  ↓
  ✅ 成功！没有异步冲突
```

---

**代码已修复，现在重启服务测试！** 🚀

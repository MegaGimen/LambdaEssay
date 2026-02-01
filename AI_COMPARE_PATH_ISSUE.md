# 🔧 AI对比功能问题诊断和解决方案

## ❌ **真正的问题**

不是"Route not found"，而是**文档提取失败**！

### **错误信息**
```
[AI对比] 错误: Exception: 提取文档失败 (commit: 6f1dd65...): 
fatal: path 'doc_content\content.docx' does not exist in '6f1dd65...'
```

### **问题原因**
后端代码中**硬编码了文档路径** `doc_content\content.docx`，但是：
1. 你的仓库中文档可能不在这个路径
2. 或者文档文件名不是 `content.docx`
3. 或者根本没有这个文件

---

## 🔍 **如何找到正确的文档路径**

### **方法1: 手动查看仓库**
1. 打开仓库文件夹（例如 `C:\Users\ADMID\AppData\Roaming\gitdocx\测试3`）
2. 查看里面有哪些 `.docx`、`.pptx`、`.xlsx` 文件
3. 记住文件的路径

### **方法2: 使用Git命令**
在仓库目录下运行：
```bash
git ls-tree -r --name-only HEAD | findstr /i "\.docx$ \.pptx$ \.xlsx$"
```

这会列出所有文档文件的路径。

---

## ✅ **解决方案**

### **临时解决方案：修改后端代码**

需要修改 `server/lib/git_service.dart` 中的文档提取逻辑，让它：
1. **动态查找文档文件**，而不是硬编码路径
2. 或者**接受前端传递的文件路径**

### **快速测试方案：使用正确的仓库**

你需要使用一个包含 `doc_content\content.docx` 文件的仓库，或者我们可以：
1. 创建一个测试仓库
2. 在里面添加 `doc_content\content.docx`
3. 提交几个版本
4. 然后测试AI对比

---

## 🎯 **推荐的修复方案**

让我修改后端代码，让它能**自动查找文档文件**：

### **修改思路**

在 `server/lib/git_service.dart` 的 `_extractDocFromCommit` 函数中：

**当前代码（硬编码路径）**：
```dart
final docPath = 'doc_content\\content.docx'; // 固定路径
```

**修改后（动态查找）**：
```dart
// 1. 先列出commit中的所有文件
final result = await Process.run('git', ['ls-tree', '-r', '--name-only', commitId], workingDirectory: repoPath);

// 2. 找到第一个匹配的文档文件
final lines = result.stdout.toString().split('\n');
String? docPath;
for (final line in lines) {
  if (line.endsWith('.docx') || line.endsWith('.pptx') || line.endsWith('.xlsx')) {
    docPath = line.trim();
    break;
  }
}

if (docPath == null) {
  throw Exception('在commit $commitId 中找不到文档文件');
}
```

---

## 🚀 **现在的选择**

### **选项A: 我帮你修改后端代码** ⭐⭐⭐⭐⭐
- 让它自动查找文档文件
- 这样任何仓库都能用
- **推荐这个！**

### **选项B: 你创建一个测试仓库**
- 按照固定路径 `doc_content\content.docx` 创建文档
- 提交几个版本
- 然后测试

### **选项C: 告诉我你的文档实际路径**
- 告诉我你仓库中文档的实际路径
- 我把后端的硬编码路径改成你的路径

---

## 💡 **我的建议**

**选择"选项A"**，让我修改后端代码，实现自动文档查找功能。

这样：
- ✅ 任何仓库都能用
- ✅ 不需要固定的文件结构
- ✅ 更智能、更灵活

**你同意吗？我现在就开始修改！** 🚀

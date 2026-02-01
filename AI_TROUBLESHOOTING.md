# 🔍 AI服务不可用问题诊断

## 📊 **当前状态检查**

### ✅ **服务运行状态**
- ✅ Python AI 服务 (8765) - 正常运行
- ✅ Dart 后端 (8080) - 正常运行
- ✅ 前端已连接

### ❌ **问题所在**

根据你的截图和测试，问题是：

---

## 🎯 **问题1: 你使用的是旧版本的应用**

### **证据**：
从截图看到的界面布局：
- ❌ **没有左右分栏**
- ❌ 只显示提交信息 + "AI服务不可用"
- ✅ 这是**旧版本的界面**

### **原因**：
最新的编译在 **03:47:06**（约1小时前）完成，但你的应用可能：
1. 是更早启动的
2. 没有关闭重启
3. 使用的是缓存的旧版本

### **解决方法**：

**完全关闭并重启应用**：

1. **关闭所有窗口**
   - 关闭当前的 `git_graph_web.exe`
   - 确保进程完全退出

2. **重新启动**
   ```powershell
   # 方式1: 双击最新编译的exe
   E:\lambaessay_project\LambdaEssay\frontend\build\windows\x64\runner\Release\git_graph_web.exe
   
   # 方式2: 使用启动脚本
   E:\lambaessay_project\LambdaEssay\start_app.bat
   ```

---

## 🎯 **问题2: 前端代码的数据提取可能有误**

即使用了新版本，AI接口返回500错误。可能的原因：

### **后端返回的数据结构**：
```json
{
  "success": true,
  "commit1": "abc123",
  "commit2": "def456",
  "docType": "word",
  "result": {
    "summary": "...",
    "major_changes": [...],
    "detailed_changes": "...",
    "doc_type": "word",
    "cached": false
  }
}
```

### **前端期望的结构**：
当前代码直接用 `result['doc_type']`，但应该是 `result['result']['doc_type']`

---

## ✅ **立即验证步骤**

### **步骤1: 确认编译文件是最新的**

```powershell
Get-Item "e:\lambaessay_project\LambdaEssay\frontend\build\windows\x64\runner\Release\git_graph_web.exe" | Select-Object LastWriteTime
```

应该显示：**2026-02-01 03:47:06** 或更晚

---

### **步骤2: 完全重启应用**

```powershell
# 1. 关闭所有 git_graph_web 进程
Get-Process | Where-Object {$_.ProcessName -like "*git_graph*"} | Stop-Process -Force

# 2. 重新启动
E:\lambaessay_project\LambdaEssay\start_app.bat
```

---

### **步骤3: 测试新界面**

1. 打开项目
2. 点击任意提交节点
3. **应该看到左右分栏**：
   - 左侧：AI 智能分析（蓝色背景）
   - 右侧：PDF 详细对比

如果**还是旧界面**（只有提交信息，没有分栏），说明应用没有更新。

---

## 🔧 **如果仍然显示"AI服务不可用"**

### **调试步骤**：

**1. 查看Dart后端日志**

应该能看到：
```
[API] AI对比请求: xxx vs yyy (word)
[AI对比] 提取文档: xxx vs yyy (word)
[AI对比] 调用 AI 服务...
[AI对比] 分析完成
```

或错误信息：
```
[API] AI对比失败: xxxxx
```

**2. 检查是否是初始提交**

如果你点击的是**第一个提交**，确实没有父节点可对比，会显示提示。

**3. 检查文档是否能提取**

后端需要用 `git show commit:path` 提取文档，如果文档不存在会失败。

---

## 📋 **完整的诊断清单**

| 检查项 | 预期 | 如何验证 |
|--------|------|----------|
| Python AI 服务 | ✅ 运行 | `netstat -ano \| findstr ":8765.*LISTENING"` |
| Dart 后端 | ✅ 运行 | `netstat -ano \| findstr ":8080.*LISTENING"` |
| 编译文件时间 | 03:47 或更晚 | 查看文件属性 |
| 应用版本 | 新版（分栏布局） | 打开应用查看界面 |
| 提交有父节点 | ✅ 不是初始提交 | 查看 Git 历史 |

---

## 🚀 **推荐操作**

### **最快的验证方法**：

```powershell
# 1. 停止所有相关进程
Get-Process | Where-Object {$_.ProcessName -like "*git_graph*" -or $_.ProcessName -like "*dart*"} | Stop-Process -Force

# 2. 重新启动所有服务
cd E:\lambaessay_project\LambdaEssay
.\start_app.bat
```

然后：
1. 打开项目
2. 确保有至少 2 个提交
3. 点击**第二个或更后的提交**（不是第一个）
4. 查看是否出现**左右分栏界面**

---

## 💡 **关键判断标准**

### **如果看到左右分栏** → 新版本成功
```
[ AI分析 (左侧) | PDF对比 (右侧) ]
```

### **如果只看到提交信息** → 旧版本
```
[ 提交信息 + PDF预览 (右侧小窗) ]
```

---

**我的建议：先彻底关闭应用，然后重新运行最新编译的exe，看看界面是否变化！**

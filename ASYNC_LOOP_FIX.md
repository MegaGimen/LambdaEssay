# ✅ 异步事件循环冲突问题修复

## ❌ **错误信息**
```
AI服务调用失败: Detected a running event loop; call this from async context.
```

## 🔍 **问题原因**

### **事件循环冲突**

1. **FastAPI** (Python AI服务 `api_server.py`) 启动时创建了一个事件循环
2. 当处理HTTP请求时，FastAPI在这个事件循环中执行代码
3. **MCP调用**（`mcp_markitdown.py`）试图创建或使用新的事件循环
4. Python不允许在已有事件循环的上下文中创建新的事件循环 → **冲突！**

### **具体流程**

```
前端 → Dart后端 → Python AI服务(FastAPI) → LambdaLinker对比
                     ↓ (已有事件循环)
                   调用MCP
                     ↓ (试图创建新事件循环)
                   ❌ 冲突！
```

---

## 🔧 **修复方案**

### **修改文件**
`LambdaLinker/mcp_modules/mcp_markitdown.py` - `run_async` 函数

### **修复前（有问题）**
```python
def run_async(coro: Any) -> Any:
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    
    # 简单的防止重入检查
    if loop.is_running():
        raise RuntimeError("检测到正在运行的 Event Loop...")
    return loop.run_until_complete(coro)
```

**问题**：
- 检测到事件循环正在运行时，直接抛出异常
- 没有处理FastAPI环境下的情况

### **修复后（兼容）**
```python
def run_async(coro: Any) -> Any:
    """运行异步协程，兼容已有事件循环"""
    try:
        loop = asyncio.get_running_loop()
        # 如果已经在事件循环中，创建新的线程来运行
        import concurrent.futures
        import threading
        
        result = None
        exception = None
        
        def run_in_thread():
            nonlocal result, exception
            try:
                new_loop = asyncio.new_event_loop()
                asyncio.set_event_loop(new_loop)
                result = new_loop.run_until_complete(coro)
                new_loop.close()
            except Exception as e:
                exception = e
        
        thread = threading.Thread(target=run_in_thread)
        thread.start()
        thread.join()
        
        if exception:
            raise exception
        return result
        
    except RuntimeError:
        # 没有运行中的事件循环，直接运行
        return asyncio.run(coro)
```

**优点**：
- ✅ 检测到已有事件循环时，在**新线程**中运行
- ✅ 新线程中创建**独立的事件循环**
- ✅ 不与FastAPI的事件循环冲突
- ✅ 兼容非异步环境（直接运行）

---

## 🎯 **工作原理**

### **场景1: FastAPI环境（有事件循环）**
```python
try:
    loop = asyncio.get_running_loop()  # ✅ 成功，检测到FastAPI的事件循环
    # 创建新线程 →
    #   在新线程中创建独立的事件循环 →
    #   在独立的事件循环中运行MCP调用 →
    #   不冲突！
except RuntimeError:
    # 不会执行这里
```

### **场景2: 非异步环境（无事件循环）**
```python
try:
    loop = asyncio.get_running_loop()  # ❌ 抛出RuntimeError
except RuntimeError:
    return asyncio.run(coro)  # ✅ 直接运行
```

---

## 📊 **修复状态**

| 文件 | 状态 | 说明 |
|------|------|------|
| `mcp_modules/mcp_word.py` | ✅ 已修复 | 之前就修复了 |
| `mcp_modules/mcp_markitdown.py` | ✅ 刚刚修复 | 使用新的 `run_async` |

---

## 🚀 **测试步骤**

### **重要：需要重启Python AI服务！**

因为修改了Python代码，必须重启服务才能生效。

#### **方法1: 重启服务（推荐）**

**停止当前服务**：
```powershell
# 查找并停止Python AI服务
Get-Process | Where-Object {$_.ProcessName -eq "python" -or $_.ProcessName -eq "uvicorn"} | Stop-Process -Force
```

**重新启动**：
```powershell
cd e:\lambaessay_project\LambdaEssay\LambdaLinker
.\start_api.bat
```

#### **方法2: 手动重启**

1. 找到运行Python AI服务的窗口
2. 按 `Ctrl+C` 停止
3. 重新运行 `start_api.bat`

---

### **然后在前端测试**

1. ✅ 确保Python AI服务已重启
2. ✅ 确保Dart后端运行中
3. ✅ 在前端选择两个节点
4. ✅ 点击"AI智能对比"
5. ✅ 查看结果

---

## 🎉 **预期结果**

### **成功标志** ✅
- 不再显示 "Detected a running event loop"
- AI对比窗口正常弹出
- 显示AI分析结果：
  - 📊 变更摘要
  - ✏️ 主要变化
  - 📝 详细分析
  - 📁 文档类型
  - ⚡ 缓存状态

### **如果还有问题** ❌
- 检查Python AI服务是否真的重启了
- 查看Python服务日志
- 告诉我新的错误信息

---

## 📝 **技术说明**

### **为什么在新线程中运行？**

**FastAPI的事件循环**在主线程运行，处理HTTP请求。

**MCP调用**需要自己的事件循环来执行异步IO。

**冲突**：不能在一个线程中同时运行两个事件循环。

**解决**：
1. 在主线程检测到FastAPI的事件循环
2. 创建新线程
3. 在新线程中创建独立的事件循环
4. 在独立的事件循环中执行MCP调用
5. 等待新线程完成并返回结果

**结果**：两个事件循环在不同线程，互不冲突！

---

## 🎯 **下一步**

**现在立即做**：

1. **重启Python AI服务**（最重要！）
   ```powershell
   cd e:\lambaessay_project\LambdaEssay\LambdaLinker
   .\start_api.bat
   ```

2. **在前端测试**
   - 选择两个节点
   - 点击"AI智能对比"

3. **告诉我结果**
   - 成功了？还是还有错误？

---

**代码已修复，现在重启Python AI服务，然后测试！** 🚀

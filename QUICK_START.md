# 🚀 LambdaEssay 快速启动指南

## 📦 **Release 编译完成！**

恭喜！你的应用已成功编译为独立的 Windows 可执行文件。

---

## 🎯 **一键启动（推荐）**

### **方法 1: 使用启动脚本**

双击运行：
```
E:\lambaessay_project\LambdaEssay\启动应用.bat
```

这个脚本会自动：
1. ✅ 检查并启动 Dart 后端服务（如未运行）
2. ✅ 检查并启动 Python AI 服务（如未运行）
3. ✅ 启动 LambdaEssay 前端应用

**所有服务会自动在后台运行！**

---

## 🔧 **手动启动（高级用户）**

如果需要手动控制各个服务：

### **步骤 1: 启动 Dart 后端**

```powershell
cd E:\lambaessay_project\LambdaEssay\server
dart run bin/server.dart
```

服务会监听在 `http://127.0.0.1:8080`

---

### **步骤 2: 启动 Python AI 服务**（可选，如需 AI 对比功能）

```powershell
cd E:\lambaessay_project\LambdaEssay\LambdaLinker
.\start_api.bat
```

服务会监听在 `http://127.0.0.1:8765`

---

### **步骤 3: 启动前端应用**

直接双击运行：
```
E:\lambaessay_project\LambdaEssay\frontend\build\windows\x64\runner\Release\git_graph_web.exe
```

或使用命令行：
```powershell
cd E:\lambaessay_project\LambdaEssay\frontend\build\windows\x64\runner\Release
.\git_graph_web.exe
```

---

## 📂 **文件位置说明**

### **可执行文件**
```
E:\lambaessay_project\LambdaEssay\frontend\build\windows\x64\runner\Release\git_graph_web.exe
```

**大小**: 81 KB  
**类型**: Windows 可执行文件 (.exe)  
**依赖**: 需要同目录下的 DLL 文件和 data 文件夹

### **完整应用文件夹**
```
E:\lambaessay_project\LambdaEssay\frontend\build\windows\x64\runner\Release\
├── git_graph_web.exe           # 主程序
├── flutter_windows.dll          # Flutter 运行时
├── pdfium.dll                   # PDF 预览支持
├── syncfusion_pdfviewer_windows_plugin.dll
├── url_launcher_windows_plugin.dll
└── data\                        # 应用资源文件
    ├── app.so                   # Dart 编译后的代码
    ├── flutter_assets\          # Flutter 资源
    └── icudtl.dat               # 国际化数据
```

**重要**: 如果要移动应用，必须将整个 `Release` 文件夹一起复制！

---

## 🎮 **应用使用说明**

### **主要功能**

1. **文档版本管理**
   - 创建/打开项目
   - 追踪 Word/Excel/PPT 文档变化
   - 提交版本、查看历史

2. **Git 分支可视化**
   - 图形化展示提交历史
   - 分支操作（创建、切换、合并）
   - 选择 2 个提交进行对比

3. **文档对比**
   - PDF 差异对比（传统方式）
   - AI 智能对比（需启动 Python AI 服务）
   - 查看详细变更内容

4. **远程协作**
   - 推送/拉取到远程仓库
   - 多人协作编辑
   - 冲突解决

---

## ⚠️ **常见问题**

### **Q1: 应用无法连接服务器**

**原因**: Dart 后端未启动

**解决方法**:
```powershell
cd E:\lambaessay_project\LambdaEssay\server
dart run bin/server.dart
```

确保看到 `Server listening on http://127.0.0.1:8080`

---

### **Q2: AI 对比功能不可用**

**原因**: Python AI 服务未启动

**解决方法**:
```powershell
cd E:\lambaessay_project\LambdaEssay\LambdaLinker
.\start_api.bat
```

确保看到 `INFO:     Uvicorn running on http://127.0.0.1:8765`

---

### **Q3: 需要重新编译**

**开发模式**（支持热重载）:
```powershell
cd E:\lambaessay_project\LambdaEssay\frontend
flutter run -d windows
```

**Release 模式**（生成新的 exe）:
```powershell
cd E:\lambaessay_project\LambdaEssay\frontend
flutter build windows --release
```

---

## 📊 **服务端口说明**

| 服务 | 端口 | 用途 |
|------|------|------|
| Dart 后端 | 8080 | 主要业务逻辑、Git 操作 |
| Python AI 服务 | 8765 | AI 智能文档对比 |
| 前端应用 | - | 客户端 UI（不占用端口）|
| Alive Check | 9527 | 前端健康检查 |

---

## 🎯 **验证安装**

启动应用后，检查以下内容：

1. ✅ 前端窗口正常打开
2. ✅ 可以创建/打开项目
3. ✅ Dart 后端日志显示 `Server listening on http://127.0.0.1:8080`
4. ✅ （可选）Python AI 服务日志显示 `Uvicorn running on http://127.0.0.1:8765`

---

## 📦 **打包分发（未来）**

如果需要分发给其他用户，建议：

1. **打包整个 Release 文件夹**
2. **创建安装程序**（使用 NSIS 或 Inno Setup）
3. **包含 Dart 后端服务**（可编译为独立 exe）
4. **包含 Python AI 服务**（可使用 PyInstaller 打包）

详见 `BUILD_AND_PACKAGE_GUIDE.md`

---

## 🆘 **需要帮助？**

- 查看项目根目录的 `README.md`
- 查看 AI 缓存说明：`LambdaLinker/CACHE_GUIDE.md`
- 查看集成文档：`INTEGRATION_COMPLETE.md`

---

**祝使用愉快！** 🎊

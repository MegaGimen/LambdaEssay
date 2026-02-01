# ⚠️ 编译环境配置指南

## 📋 当前状态

已检测到：
- ✅ Python 3.12.4 已安装
- ❌ Flutter 未在 PATH 中
- ❌ Dart 未在 PATH 中

## 🔧 需要安装的工具

### 1. 安装 Flutter SDK

**下载地址**：https://flutter.dev/docs/get-started/install/windows

**安装步骤**：
```powershell
# 1. 下载 Flutter SDK
# 2. 解压到 C:\flutter
# 3. 添加到 PATH：
#    C:\flutter\bin

# 4. 验证安装
flutter doctor -v
```

### 2. Dart SDK（Flutter 自带）

Flutter 已包含 Dart SDK，无需单独安装。

### 3. 配置 Flutter

```powershell
# 启用 Windows 桌面支持
flutter config --enable-windows-desktop

# 检查环境
flutter doctor
```

---

## 🚀 安装完成后的编译步骤

### 方式 1: 使用自动脚本

```powershell
# 确保 Flutter 在 PATH 中后运行：
.\build_all.bat
```

### 方式 2: 手动编译

#### 步骤 1: 编译 Flutter 前端
```powershell
# 获取依赖
flutter pub get

# 编译 Windows 版本
flutter build windows --release

# 输出：build\windows\x64\runner\Release\
```

#### 步骤 2: 编译 Dart 后端
```powershell
cd server

# 编译为可执行文件
dart compile exe bin/server.dart -o server.exe

# 输出：server/server.exe
```

#### 步骤 3: 打包 Python AI 服务
```powershell
cd LambdaLinker

# 激活虚拟环境
.\venv\Scripts\Activate.ps1

# 安装 PyInstaller
pip install pyinstaller

# 打包
pyinstaller --onefile ^
  --name=ai_service ^
  --add-data "mcp_modules;mcp_modules" ^
  --add-data "core;core" ^
  api_server.py

# 输出：LambdaLinker/dist/ai_service.exe
```

---

## 🎯 临时解决方案

在安装 Flutter 之前，你可以：

### 1. 只编译 Python AI 服务

我可以帮你先编译 Python 部分（AI 服务）。

### 2. 使用开发模式运行

```powershell
# 终端 1: Python AI 服务
cd LambdaLinker
.\venv\Scripts\python.exe api_server.py

# 终端 2: 安装 Flutter 后运行
# flutter run -d windows
```

---

## 📝 安装 Flutter 的快速指南

### 使用 Chocolatey（推荐）

```powershell
# 以管理员身份运行 PowerShell

# 1. 安装 Chocolatey（如果未安装）
Set-ExecutionPolicy Bypass -Scope Process -Force; 
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# 2. 安装 Flutter
choco install flutter

# 3. 重启终端后验证
flutter doctor
```

### 手动安装

1. 访问：https://docs.flutter.dev/get-started/install/windows
2. 下载 Flutter SDK zip 文件
3. 解压到 `C:\flutter`
4. 添加环境变量：
   - 变量名：`Path`
   - 添加值：`C:\flutter\bin`
5. 重启终端
6. 运行 `flutter doctor`

---

## ✅ 验证安装

安装完成后运行：

```powershell
# 检查 Flutter
flutter --version

# 检查 Dart
dart --version

# 检查 Python
python --version

# 全部成功后，运行编译脚本
.\build_all.bat
```

---

## 🆘 需要帮助？

### 选项 1: 我先帮你编译 Python 部分

如果你想先看到部分成果，我可以：
1. 编译 Python AI 服务
2. 创建基本的目录结构
3. 准备启动脚本

### 选项 2: 安装 Flutter 后继续

1. 按照上面的指南安装 Flutter
2. 重新运行编译脚本
3. 获得完整的客户端程序

---

## 📞 下一步

请选择：

**A. 先编译 Python 部分**
```
我会立即编译 Python AI 服务，让你看到部分成果
```

**B. 等待安装 Flutter**
```
你先安装 Flutter，然后我们继续完整编译
```

**C. 使用开发模式**
```
暂时不编译，使用开发模式运行程序
```

你想选择哪个？

# 📦 LambdaEssay 客户端编译与打包指南

## 🎯 目标

将 LambdaEssay 项目编译成一个**可分发的 Windows 桌面应用程序**，用户只需双击 `.exe` 文件即可使用。

---

## 📊 当前项目架构

```
LambdaEssay 完整应用
│
├── 前端界面 (Flutter Desktop)
│   ├── 文件: lib/main.dart
│   ├── 功能: Git 可视化、分支管理、文档预览
│   └── 编译: flutter build windows
│
├── 后端服务 (Dart Server)
│   ├── 文件: server/bin/server.dart
│   ├── 功能: Git 操作、文档对比、API 端点
│   └── 编译: dart compile exe
│
└── AI 服务 (Python)
    ├── 文件: LambdaLinker/api_server.py
    ├── 功能: AI 文档分析、智能缓存
    └── 打包: PyInstaller
```

---

## 🚀 编译步骤

### 步骤 1: 编译 Flutter 前端

```powershell
# 进入项目根目录
cd E:\lambaessay_project\LambdaEssay

# 确保依赖已安装
flutter pub get

# 编译 Windows 版本（Release 模式）
flutter build windows --release

# 输出位置：
# build\windows\x64\runner\Release\LambdaEssay.exe
```

**生成文件**：
- `LambdaEssay.exe` - 主程序
- `flutter_windows.dll` - Flutter 运行时
- `data/` - 资源文件
- 其他依赖 DLL

---

### 步骤 2: 编译 Dart 后端

```powershell
# 进入后端目录
cd server

# 编译为独立可执行文件
dart compile exe bin/server.dart -o server.exe

# 输出位置：
# server/server.exe
```

**优点**：
- 单个 .exe 文件
- 不需要 Dart SDK
- 启动速度快

---

### 步骤 3: 打包 Python AI 服务

```powershell
# 进入 Python 服务目录
cd LambdaLinker

# 激活虚拟环境
.\venv\Scripts\Activate.ps1

# 安装 PyInstaller
pip install pyinstaller

# 打包成单个可执行文件
pyinstaller --onefile `
  --add-data "mcp_modules;mcp_modules" `
  --add-data "core;core" `
  --hidden-import="openai" `
  --hidden-import="fastapi" `
  --hidden-import="uvicorn" `
  api_server.py

# 输出位置：
# LambdaLinker/dist/api_server.exe
```

---

### 步骤 4: 复制 Git 便携版

```powershell
# 下载 Git Portable（如果还没有）
# 链接: https://git-scm.com/download/win
# 选择: Portable ("thumbdrive edition")

# 解压到项目目录
# 应该有: mingw64\bin\git.exe
```

---

### 步骤 5: 组织目录结构

创建发布目录：

```
LambdaEssay_Release/
│
├── LambdaEssay.exe           ← Flutter 主程序
├── flutter_windows.dll       ← Flutter 运行时
├── data/                      ← Flutter 资源
│
├── server/
│   └── server.exe            ← Dart 后端服务
│
├── ai_service/
│   ├── api_server.exe        ← Python AI 服务
│   └── .env                  ← 配置文件（LLM API Key）
│
├── mingw64/                   ← Git 便携版
│   └── bin/
│       └── git.exe
│
├── frontend/
│   └── lib/
│       ├── doccmp.ps1        ← 文档对比脚本
│       └── docx2pdf.ps1      ← PDF 转换脚本
│
└── start.bat                 ← 启动脚本
```

---

### 步骤 6: 创建启动脚本

**`start.bat`**：

```batch
@echo off
title LambdaEssay 文档管理系统

:: 设置工作目录
cd /d "%~dp0"

:: 检查配置
if not exist "ai_service\.env" (
    echo [错误] 未找到配置文件！
    echo 请先配置 ai_service\.env 中的 LLM_API_KEY
    pause
    exit /b 1
)

:: 启动 Python AI 服务（后台）
echo [启动] AI 智能分析服务...
start /B "" ai_service\api_server.exe

:: 等待服务启动
timeout /t 3 /nobreak >nul

:: 启动 Dart 后端服务（后台）
echo [启动] 后端服务...
start /B "" server\server.exe

:: 等待服务启动
timeout /t 2 /nobreak >nul

:: 启动 Flutter 主程序
echo [启动] LambdaEssay 客户端...
start "" LambdaEssay.exe

echo.
echo ========================================
echo    LambdaEssay 已启动！
echo ========================================
echo.
echo 提示：关闭此窗口将停止所有服务
echo.

:: 保持窗口打开（可选）
:: pause
```

---

### 步骤 7: 创建配置向导

**`config_wizard.bat`**：

```batch
@echo off
title LambdaEssay 配置向导

echo ========================================
echo    LambdaEssay 首次配置向导
echo ========================================
echo.

:: 检查 .env 文件
if exist "ai_service\.env" (
    echo [提示] 发现现有配置文件
    set /p overwrite="是否重新配置？(Y/N): "
    if /i not "%overwrite%"=="Y" goto :eof
)

echo.
echo 请输入您的 LLM API 配置：
echo.

:: 输入 API Key
set /p api_key="1. API Key: "

:: 选择 API 提供商
echo.
echo 2. API 提供商:
echo    [1] 阿里云 DashScope (推荐)
echo    [2] OpenAI
echo    [3] 其他 OpenAI 兼容服务
set /p provider="请选择 (1-3): "

:: 设置对应的 Base URL 和模型
if "%provider%"=="1" (
    set base_url=https://dashscope.aliyuncs.com/compatible-mode/v1
    set model=qwen-plus
) else if "%provider%"=="2" (
    set base_url=https://api.openai.com/v1
    set model=gpt-4o-mini
) else (
    set /p base_url="   Base URL: "
    set /p model="   模型名称: "
)

:: 生成配置文件
echo.
echo [生成] 配置文件...

(
echo LLM_API_KEY=%api_key%
echo LLM_BASE_URL=%base_url%
echo LLM_MODEL_ID=%model%
echo LLM_TEMPERATURE=0.2
echo LLM_TIMEOUT=60
echo LLM_MAX_TOKENS=
echo LLM_MAX_RETRIES=
echo.
echo # Feature flags
echo PRINT_PROMPTS=1
echo.
echo # Cache settings
echo LAMBDALINKER_CACHE_ENABLED=1
echo LAMBDALINKER_CACHE_MAX_SIZE_MB=500
echo LAMBDALINKER_CACHE_MAX_ENTRIES=1000
) > ai_service\.env

echo.
echo ========================================
echo    配置完成！
echo ========================================
echo.
echo 您现在可以运行 start.bat 启动程序
echo.
pause
```

---

## 📦 创建安装包（可选）

### 使用 NSIS 创建安装程序

1. **安装 NSIS**
   - 下载：https://nsis.sourceforge.io/
   - 安装到默认位置

2. **创建安装脚本** (`installer.nsi`)

```nsis
!include "MUI2.nsh"

# 基本信息
Name "LambdaEssay"
OutFile "LambdaEssay_Setup.exe"
InstallDir "$PROGRAMFILES\LambdaEssay"
InstallDirRegKey HKLM "Software\LambdaEssay" "Install_Dir"

# 界面设置
!define MUI_ICON "icon.ico"
!define MUI_HEADERIMAGE
!define MUI_ABORTWARNING

# 页面
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

# 语言
!insertmacro MUI_LANGUAGE "SimpChinese"

# 安装部分
Section "安装" SecMain
  SetOutPath "$INSTDIR"
  
  # 复制所有文件
  File /r "LambdaEssay_Release\*"
  
  # 创建快捷方式
  CreateDirectory "$SMPROGRAMS\LambdaEssay"
  CreateShortcut "$SMPROGRAMS\LambdaEssay\LambdaEssay.lnk" "$INSTDIR\start.bat" "" "$INSTDIR\LambdaEssay.exe"
  CreateShortcut "$SMPROGRAMS\LambdaEssay\配置.lnk" "$INSTDIR\config_wizard.bat"
  CreateShortcut "$DESKTOP\LambdaEssay.lnk" "$INSTDIR\start.bat" "" "$INSTDIR\LambdaEssay.exe"
  
  # 写入注册表
  WriteRegStr HKLM "Software\LambdaEssay" "Install_Dir" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\LambdaEssay" "DisplayName" "LambdaEssay"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\LambdaEssay" "UninstallString" '"$INSTDIR\uninstall.exe"'
  
  # 创建卸载程序
  WriteUninstaller "$INSTDIR\uninstall.exe"
SectionEnd

# 卸载部分
Section "Uninstall"
  Delete "$INSTDIR\*"
  RMDir /r "$INSTDIR"
  Delete "$SMPROGRAMS\LambdaEssay\*"
  RMDir "$SMPROGRAMS\LambdaEssay"
  Delete "$DESKTOP\LambdaEssay.lnk"
  DeleteRegKey HKLM "Software\LambdaEssay"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\LambdaEssay"
SectionEnd
```

3. **编译安装包**

```powershell
makensis installer.nsi
```

生成：`LambdaEssay_Setup.exe`（约 200-300 MB）

---

## ✅ 验证清单

编译完成后，测试以下功能：

- [ ] 双击 `start.bat` 能启动所有服务
- [ ] Flutter 界面正常显示
- [ ] 可以打开/创建 Git 仓库
- [ ] 可以查看提交历史和分支
- [ ] PDF 预览功能正常
- [ ] AI 对比功能正常（需配置 API Key）
- [ ] 缓存统计正常显示

---

## 📤 分发给用户

### 方式 1: 便携版（推荐）

打包成 `.zip` 文件：

```
LambdaEssay_v1.0.0_Portable.zip
  └── LambdaEssay_Release/
      └── [所有文件]
```

**用户使用步骤**：
1. 解压到任意目录
2. 运行 `config_wizard.bat` 配置 API Key
3. 运行 `start.bat` 启动程序

### 方式 2: 安装包

提供 `LambdaEssay_Setup.exe`：

**用户使用步骤**：
1. 双击安装包
2. 按照向导完成安装
3. 首次运行会提示配置 API Key
4. 从开始菜单或桌面快捷方式启动

---

## 📝 用户文档

创建 `README_用户指南.txt`：

```
========================================
   LambdaEssay 文档管理系统
========================================

版本: 1.0.0
更新日期: 2026-01-31

## 快速开始

1. 首次运行
   - 运行 config_wizard.bat 配置 API Key
   - 如果已有配置，直接运行 start.bat

2. 创建文档项目
   - 点击"新建项目"
   - 选择文档位置
   - 系统自动初始化 Git 仓库

3. 编辑和提交
   - 在 Word 中编辑文档
   - 回到程序点击"保存版本"
   - 输入提交信息

4. 查看历史
   - 左侧显示所有历史版本
   - 点击任意版本查看 PDF 预览
   - 右键选择"对比版本"

5. AI 智能对比
   - 选择两个版本
   - 点击"AI 对比"
   - 查看智能分析结果

## 常见问题

Q: 如何配置 API Key？
A: 运行 config_wizard.bat 或手动编辑 ai_service\.env

Q: 程序启动慢？
A: 首次启动需要加载服务，后续会更快

Q: 如何备份数据？
A: 文档和版本历史都在项目文件夹中

## 技术支持

遇到问题请查看日志文件或联系开发者
```

---

## 🎯 总结

你的项目**完全可以编译成独立的桌面客户端**！

**三种交付方式**：

1. **开发版**：需要三个终端（当前状态）
2. **便携版**：解压即用（推荐新手）
3. **安装版**：专业的安装程序（推荐企业）

下一步你可以：
1. 按照步骤编译各个组件
2. 测试打包后的程序
3. 根据需要创建安装包
4. 分发给用户使用

需要我帮你执行编译步骤吗？

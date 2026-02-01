@echo off
REM ========================================
REM  LambdaEssay 一键编译脚本
REM ========================================

title LambdaEssay 编译工具

echo.
echo ========================================
echo    LambdaEssay 自动编译
echo ========================================
echo.

:: 设置颜色（可选）
color 0A

:: 检查必要工具
echo [检查] 编译环境...
echo.

:: 检查 Flutter
where flutter >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 Flutter！
    echo        请先安装 Flutter: https://flutter.dev/
    pause
    exit /b 1
)

:: 检查 Dart
where dart >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 Dart SDK！
    echo        Flutter 应该包含 Dart，请检查 PATH 配置
    pause
    exit /b 1
)

:: 检查 Python
where python >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 Python！
    echo        请先安装 Python 3.8+
    pause
    exit /b 1
)

echo [通过] 所有编译工具已就绪
echo.

:: 创建输出目录
set OUTPUT_DIR=LambdaEssay_Release
if exist "%OUTPUT_DIR%" (
    echo [清理] 删除旧的发布目录...
    rmdir /s /q "%OUTPUT_DIR%"
)

mkdir "%OUTPUT_DIR%"
mkdir "%OUTPUT_DIR%\server"
mkdir "%OUTPUT_DIR%\ai_service"
mkdir "%OUTPUT_DIR%\frontend\lib"

echo.
echo ========================================
echo  步骤 1/4: 编译 Flutter 前端
echo ========================================
echo.

:: 获取依赖
echo [执行] flutter pub get...
call flutter pub get

:: 编译 Windows 版本
echo [编译] Flutter Windows Release...
call flutter build windows --release

if errorlevel 1 (
    echo [失败] Flutter 编译失败！
    pause
    exit /b 1
)

:: 复制 Flutter 输出
echo [复制] Flutter 编译结果...
xcopy /E /I /Y build\windows\x64\runner\Release\* "%OUTPUT_DIR%\" >nul

echo [完成] Flutter 前端编译成功
echo.

:: ========================================
echo.
echo ========================================
echo  步骤 2/4: 编译 Dart 后端
echo ========================================
echo.

cd server

echo [编译] Dart 后端服务...
dart compile exe bin\server.dart -o server.exe

if errorlevel 1 (
    echo [失败] Dart 后端编译失败！
    cd ..
    pause
    exit /b 1
)

:: 移动到输出目录
move server.exe ..\%OUTPUT_DIR%\server\ >nul

cd ..
echo [完成] Dart 后端编译成功
echo.

:: ========================================
echo.
echo ========================================
echo  步骤 3/4: 打包 Python AI 服务
echo ========================================
echo.

cd LambdaLinker

:: 检查虚拟环境
if not exist "venv\Scripts\python.exe" (
    echo [警告] 虚拟环境不存在，使用系统 Python
    set PYTHON_CMD=python
) else (
    set PYTHON_CMD=venv\Scripts\python.exe
)

:: 安装 PyInstaller（如果需要）
echo [检查] PyInstaller...
%PYTHON_CMD% -m pip show pyinstaller >nul 2>&1
if errorlevel 1 (
    echo [安装] PyInstaller...
    %PYTHON_CMD% -m pip install pyinstaller
)

:: 打包 API 服务器
echo [打包] Python AI 服务（这可能需要几分钟）...
%PYTHON_CMD% -m PyInstaller --onefile --name=ai_service --add-data "mcp_modules;mcp_modules" --add-data "core;core" --hidden-import=openai --hidden-import=fastapi --hidden-import=uvicorn --hidden-import=python_docx --hidden-import=python_pptx api_server.py --log-level=WARN

if errorlevel 1 (
    echo [失败] Python 打包失败！
    cd ..
    pause
    exit /b 1
)

:: 复制到输出目录
copy dist\ai_service.exe ..\%OUTPUT_DIR%\ai_service\ >nul
copy .env ..\%OUTPUT_DIR%\ai_service\ >nul 2>&1
if not exist "..\%OUTPUT_DIR%\ai_service\.env" (
    copy .env.example ..\%OUTPUT_DIR%\ai_service\.env >nul 2>&1
)

cd ..
echo [完成] Python AI 服务打包成功
echo.

:: ========================================
echo.
echo ========================================
echo  步骤 4/4: 复制辅助文件
echo ========================================
echo.

:: 复制 PowerShell 脚本
echo [复制] 文档处理脚本...
if exist "frontend\lib\doccmp.ps1" (
    copy frontend\lib\doccmp.ps1 "%OUTPUT_DIR%\frontend\lib\" >nul
)
if exist "frontend\lib\docx2pdf.ps1" (
    copy frontend\lib\docx2pdf.ps1 "%OUTPUT_DIR%\frontend\lib\" >nul
)

:: 复制 Git（如果存在）
echo [检查] Git 便携版...
if exist "mingw64\bin\git.exe" (
    echo [复制] Git 便携版...
    xcopy /E /I /Y mingw64 "%OUTPUT_DIR%\mingw64" >nul
) else (
    echo [跳过] Git 便携版未找到（用户需自行安装 Git）
)

:: 创建启动脚本
echo [创建] 启动脚本...

(
echo @echo off
echo title LambdaEssay
echo cd /d "%%~dp0"
echo.
echo :: 启动 AI 服务
echo start /B "" ai_service\ai_service.exe
echo timeout /t 3 /nobreak ^>nul
echo.
echo :: 启动后端服务
echo start /B "" server\server.exe
echo timeout /t 2 /nobreak ^>nul
echo.
echo :: 启动主程序
echo start "" LambdaEssay.exe
echo.
echo echo LambdaEssay 已启动！
) > "%OUTPUT_DIR%\start.bat"

:: 创建配置向导
echo [创建] 配置向导...

(
echo @echo off
echo title LambdaEssay 配置
echo echo.
echo echo ========================================
echo echo    LambdaEssay API 配置向导
echo echo ========================================
echo echo.
echo set /p api_key="请输入您的 LLM API Key: "
echo echo.
echo ^(
echo echo LLM_API_KEY=%%api_key%%
echo echo LLM_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
echo echo LLM_MODEL_ID=qwen-plus
echo echo LLM_TEMPERATURE=0.2
echo ^) ^> ai_service\.env
echo echo.
echo echo 配置完成！现在可以运行 start.bat
echo pause
) > "%OUTPUT_DIR%\config.bat"

:: 复制说明文件
echo [创建] 用户指南...

(
echo LambdaEssay 使用说明
echo.
echo 1. 首次使用：运行 config.bat 配置 API Key
echo 2. 启动程序：运行 start.bat
echo 3. 创建项目：在程序中点击"新建项目"
echo 4. 编辑文档：使用 Word 编辑文档
echo 5. 保存版本：在程序中点击"提交"
echo 6. AI 对比：选择两个版本，点击"AI 对比"
echo.
echo 技术支持：查看 BUILD_AND_PACKAGE_GUIDE.md
) > "%OUTPUT_DIR%\README.txt"

echo [完成] 辅助文件已创建
echo.

:: ========================================
echo.
echo ========================================
echo    编译完成！
echo ========================================
echo.
echo 输出目录: %OUTPUT_DIR%\
echo.
echo 文件列表:
dir /B "%OUTPUT_DIR%" | findstr /V "data"
echo.
echo 总大小:
for /f "tokens=3" %%a in ('dir /s "%OUTPUT_DIR%" ^| find "个文件"') do echo   %%a 字节
echo.
echo 后续步骤:
echo   1. 测试: 进入 %OUTPUT_DIR% 运行 start.bat
echo   2. 配置: 运行 config.bat 设置 API Key
echo   3. 打包: 压缩整个 %OUTPUT_DIR% 目录为 .zip
echo   4. 分发: 将 .zip 文件发送给用户
echo.
pause

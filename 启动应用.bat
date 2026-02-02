@echo off
chcp 65001 >nul
title LambdaEssay 应用启动器

echo.
echo ========================================
echo   LambdaEssay 文档版本管理系统
echo ========================================
echo.

:: 检查 Dart 后端是否已运行
netstat -ano | findstr ":8080" | findstr "LISTENING" >nul 2>&1
if %errorlevel% equ 0 (
    echo [√] Dart 后端服务已在运行中 (端口 8080)
    echo     Python AI 服务也会随 Dart 后端自动启动
) else (
    echo [!] 正在启动 Dart 后端服务...
    echo     (Python AI 服务将自动启动)
    start "LambdaEssay 后端" /min cmd /c "cd /d %~dp0server && dart run bin/server.dart"
    timeout /t 5 /nobreak >nul
    echo [√] Dart 后端服务已启动
)

echo.
echo ========================================
echo   所有服务已就绪！
echo ========================================
echo.
echo [*] 正在启动前端应用...
echo.

:: 启动前端应用
start "" "%~dp0frontend\build\windows\x64\runner\Release\git_graph_web.exe"

timeout /t 2 /nobreak >nul

echo.
echo [√] 应用已启动！
echo.
echo 提示：
echo   - 前端应用窗口应该已经打开
echo   - Dart 后端运行在: http://localhost:8080
echo   - Python AI 服务已整合，由 Dart 后端统一管理
echo   - 关闭此窗口不会影响应用运行
echo.
echo 按任意键退出此启动器...
pause >nul

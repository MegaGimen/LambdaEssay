@echo off
chcp 65001 >nul
title LambdaEssay Application Launcher

echo.
echo ========================================
echo   LambdaEssay Document Version Manager
echo ========================================
echo.

:: Check if Dart backend is running
netstat -ano | findstr ":8080" | findstr "LISTENING" >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Dart backend is already running on port 8080
) else (
    echo [*] Starting Dart backend service...
    start "LambdaEssay Backend" /min cmd /c "cd /d %~dp0server && dart run bin/server.dart"
    timeout /t 3 /nobreak >nul
    echo [OK] Dart backend started
)

echo.

:: Check if Python AI service is running
netstat -ano | findstr ":8765" | findstr "LISTENING" >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Python AI service is already running on port 8765
) else (
    echo [*] Starting Python AI service...
    start "LambdaEssay AI Service" /min cmd /c "cd /d %~dp0LambdaLinker && call start_api.bat"
    timeout /t 3 /nobreak >nul
    echo [OK] Python AI service started
)

echo.
echo ========================================
echo   All services ready!
echo ========================================
echo.
echo [*] Launching frontend application...
echo.

:: Launch frontend application
start "" "%~dp0frontend\build\windows\x64\runner\Release\git_graph_web.exe"

timeout /t 2 /nobreak >nul

echo.
echo [OK] Application launched!
echo.
echo Info:
echo   - Frontend window should be open now
echo   - Dart backend: http://localhost:8080
echo   - Python AI service: http://localhost:8765
echo   - You can close this window safely
echo.
echo Press any key to exit launcher...
pause >nul

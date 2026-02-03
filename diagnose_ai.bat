@echo off
chcp 65001 >nul
echo.
echo ========================================
echo   AI功能诊断工具
echo ========================================
echo.

echo [1/5] 检查服务端口...
netstat -ano | findstr ":8080.*LISTENING" >nul 2>&1
if %errorlevel% equ 0 (
    echo [√] Dart后端 (8080) 正在运行
) else (
    echo [×] Dart后端 (8080) 未运行
)

netstat -ano | findstr ":8765.*LISTENING" >nul 2>&1
if %errorlevel% equ 0 (
    echo [√] Python AI服务 (8765) 正在运行
) else (
    echo [×] Python AI服务 (8765) 未运行
)

echo.
echo [2/5] 测试Python AI服务...
curl -s http://localhost:8765/ >nul 2>&1
if %errorlevel% equ 0 (
    echo [√] Python AI服务响应正常
) else (
    echo [×] Python AI服务无响应
)

echo.
echo [3/5] 测试Dart后端...
curl -s http://localhost:8080/health >nul 2>&1
if %errorlevel% equ 0 (
    echo [√] Dart后端响应正常
) else (
    echo [×] Dart后端无响应
)

echo.
echo [4/5] 检查编译文件...
if exist "e:\lambaessay_project\LambdaEssay\frontend\build\windows\x64\runner\Release\git_graph_web.exe" (
    echo [√] 编译文件存在
    dir /T:W "e:\lambaessay_project\LambdaEssay\frontend\build\windows\x64\runner\Release\git_graph_web.exe" | findstr "git_graph_web.exe"
) else (
    echo [×] 编译文件不存在
)

echo.
echo [5/5] 测试AI对比接口...
echo 正在发送测试请求...
powershell -Command "$body = '{\"repoPath\":\"test\",\"commit1\":\"abc\",\"commit2\":\"def\",\"docType\":\"word\"}'; try { Invoke-RestMethod -Uri 'http://localhost:8080/compare_ai' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 5 -ErrorAction Stop | Out-Null; Write-Host '[√] AI对比接口响应正常' -ForegroundColor Green } catch { Write-Host '[×] AI对比接口错误:' $_.Exception.Message -ForegroundColor Red }"

echo.
echo ========================================
echo   诊断完成
echo ========================================
echo.
pause

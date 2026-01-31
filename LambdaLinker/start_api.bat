@echo off
REM LambdaLinker API 服务器启动脚本

echo ================================================
echo 启动 LambdaLinker AI 服务器
echo ================================================

cd /d %~dp0

REM 检查虚拟环境
if not exist "venv" (
    echo [错误] 虚拟环境不存在，请先创建虚拟环境
    echo 运行: python -m venv venv
    pause
    exit /b 1
)

REM 激活虚拟环境
call venv\Scripts\activate.bat

REM 检查依赖
echo 检查依赖...
python -c "import fastapi, uvicorn" 2>nul
if errorlevel 1 (
    echo [警告] 缺少依赖，正在安装...
    pip install fastapi uvicorn[standard] pydantic
)

REM 检查 .env 文件
if not exist ".env" (
    echo [警告] .env 文件不存在
    if exist ".env.example" (
        echo 正在从 .env.example 复制...
        copy .env.example .env
    ) else (
        echo [错误] 请创建 .env 文件并配置 LLM API 密钥
        pause
        exit /b 1
    )
)

REM 启动服务器
echo.
echo ================================================
echo 启动 API 服务器...
echo ================================================
echo 访问地址: http://127.0.0.1:8765
echo API 文档: http://127.0.0.1:8765/docs
echo 按 Ctrl+C 停止服务器
echo ================================================
echo.

python api_server.py

pause

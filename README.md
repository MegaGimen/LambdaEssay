# LambdaEssay - Git 文档管理与 AI 对比平台

[English](#english) | [中文](#chinese)

## 项目简介

LambdaEssay 是一个基于 Flutter Web 开发的 Git 文档管理平台，集成了可视化图谱展示和 AI 文档对比功能。主要功能包括：

- **Git 仓库可视化** - 交互式查看提交历史、分支结构和合并图谱
- **文档 AI 对比** - 利用 LLM 进行 Office 文档的语义级对比
- **图片描述生成** - 使用视觉 LLM 自动生成图片内容描述
- **版本管理** - 基于 Git 的文档版本追踪和备份
- **实时协作** - 支持多人文档审阅和评论管理

## 项目架构

本项目采用前后端分离架构：

### 前端 (Frontend)
- **技术栈**: Flutter Web
- **目录**: `frontend/`
- **功能**:
  - Git 图谱可视化
  - 文档上传和管理
  - AI 对比结果展示
  - 用户交互界面

### 后端 (Backend)
- **技术栈**: Dart (Shelf 框架)
- **目录**: `server/`
- **功能**:
  - Git 操作 API
  - 文档提取和处理
  - 与 AI 服务通信
  - 用户会话管理

### AI 对比服务 (LambdaLinker)
- **技术栈**: Python + FastAPI
- **目录**: `LambdaLinker/`
- **功能**:
  - Office 文档解析（Word/PPT/Excel）
  - LLM 语义分析
  - MCP (Model Context Protocol) 服务
  - 智能缓存管理

### Office 插件
- **目录**: `wordplugin/`
- **功能**: Office 文档集成和插件支持

## 快速开始

### 环境要求

- Flutter SDK (>= 3.0)
- Dart SDK (>= 3.0)
- Python 3.8+
- Git

### 安装步骤

1. **克隆项目**
   ```bash
   git clone <repository-url>
   cd LambdaEssay
   ```

2. **安装前端依赖**
   ```bash
   cd frontend
   flutter pub get
   ```

3. **配置后端**
   ```bash
   cd server
   dart pub get
   ```

4. **安装 AI 服务依赖**
   ```bash
   cd LambdaLinker
   pip install -r requirements.txt
   ```

5. **配置环境变量**

   复制并编辑配置文件：
   ```bash
   cd LambdaLinker
   cp .env.example .env
   # 编辑 .env 文件，填入 API 密钥等配置
   ```

6. **启动服务**

   **方式一：使用启动脚本（推荐 Windows 用户）**

   双击运行项目根目录下的 `启动应用.bat` 脚本，会自动：
   - 检查并启动 Dart 后端服务（端口 8080）
   - 检查并启动 Python AI 服务（端口 8765）
   - 启动前端应用

   **方式二：手动启动**

   启动 AI 服务（默认端口 8765）：
   ```bash
   cd LambdaLinker
   python api_server.py
   ```

   启动后端服务（默认端口 8080）：
   ```bash
   cd server
   dart run bin/server.dart
   ```

   启动前端：
   ```bash
   cd frontend
   flutter run -d chrome
   ```

### 访问应用

- 前端界面: http://localhost:8080
- 后端 API: http://127.0.0.1:8080/api
- AI 服务 API: http://127.0.0.1:8765

## 功能说明

### Git 图谱可视化

- 查看完整的提交历史图
- 交互式分支浏览
- 提交详情查看
- 文件变更追踪

### 文档 AI 对比

支持三种文档类型的语义对比：

1. **Word 文档**
   - 文本内容变化
   - 评论和修订
   - 图片描述

2. **PowerPoint 演示文稿**
   - 幻灯片内容变化
   - 布局和设计变更

3. **Excel 表格**
   - 数据变化分析
   - 公式和样式变更

### MCP 服务

集成 Model Context Protocol 服务：
- MarkItDown - 文档转 Markdown
- 图片描述生成
- 语义分析增强

## 配置说明

### LambdaLinker 环境变量

```env
# LLM 配置
LLM_API_KEY=your_api_key
LLM_BASE_URL=https://api.example.com/v1
LLM_MODEL_ID=model_name

# MarkItDown 图片描述
MARKITDOWN_LLM_API_KEY=your_api_key
MARKITDOWN_LLM_BASE_URL=https://api.example.com/v1
MARKITDOWN_LLM_MODEL=qwen-vl-plus

# 功能开关
INCLUDE_COMMENTS=1
INCLUDE_IMAGES=1
PRINT_PROMPTS=0

# 缓存配置
LAMBDALINKER_CACHE_ENABLED=1
LAMBDALINKER_CACHE_DIR=./cache
```

### MCP 配置

编辑 `LambdaLinker/mcp-config.json`：

```json
{
  "mcpServers": {
    "markitdown": {
      "command": "path/to/python",
      "args": ["path/to/markitdown_mcp_server.py"],
      "env": {
        "MARKITDOWN_LLM_API_KEY": "your_key",
        "MARKITDOWN_LLM_BASE_URL": "https://api.example.com/v1"
      }
    }
  }
}
```

## 常见问题

### 图片描述生成失败

确保 MCP 配置路径正确，不要使用 `LambdaEssay-new` 等不存在的目录。

### 文档提取失败

查看后端日志，确认 Git 仓库路径正确且有读取权限。

### 性能优化

- 启用缓存避免重复调用 LLM
- 使用 `PRINT_PROMPTS=0` 减少日志输出
- 调整 LLM 参数（temperature、max_tokens）

## 开发指南

### 前端开发

```bash
cd frontend
flutter run -d chrome
# 热重载已启用，修改代码后自动刷新
```

### 后端开发

```bash
cd server
dart run bin/server.dart
# 修改代码后需重启
```

### AI 服务开发

```bash
cd LambdaLinker
python api_server.py
# 支持热重载（uvicorn --reload）
```

## 许可证

本项目采用 **GNU Affero General Public License (AGPL)** 协议。此许可证适用于本项目的所有历史版本、所有 commit 和所有分支。

---

<a name="english"></a>
## English

### Project Overview
Git Graph Visualization is a web-based tool built with Flutter for visualizing Git repositories. It allows users to interactively view commit histories, branches, and merge graphs. The project also integrates with a backend to support features like document comparison and backup management.

### Architecture
The project consists of the following main components:
- **frontend/**: The Flutter Web application that provides the user interface for visualizing the Git graph.
- **server/**: A backend server written in Dart (using `shelf`) that handles API requests, Git operations, and communicates with other services.
- **wordplugin/**: An Office Add-in designed for document integration tasks.

### License
This project is licensed under the **GNU Affero General Public License (AGPL)**.

---

<a name="chinese"></a>
## 中文

### 项目简介
Git 仓库可视化 (Git Graph Visualization) 是一个基于 Flutter 开发的 Web 端工具，旨在对 Git 仓库进行可视化展示。它允许用户交互式地查看提交历史、分支结构以及合并图谱。该项目还集成了后端服务，支持文档比较和备份管理等功能。

### 架构
本项目主要包含以下组件：
- **frontend/**: Flutter Web 前端应用，提供 Git 图谱可视化的用户界面。
- **server/**: 基于 Dart (`shelf`) 编写的后端服务器，负责处理 API 请求、Git 操作以及与其他服务的通信。
- **wordplugin/**: 用于文档集成的 Office 插件。

### 协议
本项目采用 **GNU Affero General Public License (AGPL)** 协议。**此许可证明确适用于本项目的所有历史版本、所有commit和所有分支**。
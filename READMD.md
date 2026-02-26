# LambdaEssay Developer Guide

## 项目概述 (Project Overview)

LambdaEssay 是一个基于 Flutter (前端) 和 Dart/Python (后端) 的 Word 文档版本追踪系统。它利用 Git 的底层能力，结合自定义的 `.tracking` 压缩包格式，实现了对二进制文档（主要是 Word）的高效版本控制、分支管理和嵌套结构支持。

### 技术栈 (Tech Stack)
*   **Frontend**: Flutter (Windows Desktop)
*   **Backend Server**: Dart
*   **Auxiliary Services**: Python (Flask, Celery) - 用于远程备份、AI 差异分析等。
*   **Version Control**: Git (Submodule architecture)

## 目录结构 (Directory Structure)

*   `frontend/`: Flutter 前端项目代码。
    *   `lib/main.dart`: 应用入口。
    *   `lib/views.dart`: UI 视图定义。
    *   `lib/services.dart`: 前端服务层。
    *   `lib/widgets/custom_file_tree.dart`: 左侧“窥察镜”文件树组件。
*   `server/`: 后端服务代码。
    *   `bin/server.dart`: Dart 服务器入口。
    *   `lib/git_service.dart`: 核心 Git 操作封装。
    *   `LambdaEssay_backup/`: Python 编写的备份与恢复微服务。
    *   `remote/AI-agent/`: Python AI 代理，用于文档差异分析。

## 安装与运行 (Installation & Running)

### 环境要求
*   Flutter SDK
*   Dart SDK
*   Python 3.x (用于辅助服务)
*   Git (系统路径中需可访问)

### 启动步骤 (Startup)

本项目分为前端和后端两个独立进程，开发模式下需要分别启动。

#### 1. 启动后端 (Backend)
后端负责处理文件操作、Git 命令执行和与远程服务器的通信。

```bash
cd server
dart bin/server.dart
```

*注意：后端服务启动后会监听本地端口（默认为 8080 或代码中配置的端口），前端通过 HTTP 请求与其交互。*

#### 2. 启动前端 (Frontend)
前端是用户交互界面，运行在 Windows 桌面环境。

```bash
cd frontend
flutter run -d windows
```

*注意：请确保在运行前端前，后端服务已经成功启动。*

### 编译与构建
*   **代码检查**: 使用 `flutter analyze` 检查代码规范和错误。
    *   前端: `cd frontend && flutter analyze`
    *   后端: `cd server && dart analyze`

## 核心架构说明

### 1. 追踪包 (.tracking)
`.tracking` 文件本质是 ZIP 压缩包。
*   **物理结构**: 解压后包含 `.git` 文件夹（版本库）和工作区文件。
*   **嵌套逻辑**: 采用 Git Submodule 机制。父级仓库只记录子仓库的指针（commit hash），不记录子仓库的具体文件内容。

### 2. 叶子节点架构 (Leaf Node Architecture)
*   **Root Repo**: 仅作为容器，管理目录结构 (`.gitmodules`)。
*   **Leaf Repo (Submodule)**: 实际存储 `.docx` 文档内容的仓库。
*   **操作原则**: 用户的所有版本操作（Commit, Push, Branch）实际上是针对 Leaf Repo 进行的。系统会自动同步更新 Root Repo 的指针。

### 3. 备份系统
位于 `server/LambdaEssay_backup`。
采用“仓库的仓库”模式，将用户的 Git 仓库作为对象存储在另一个备份仓库中，防止 Force Push 导致的数据丢失。

## 调试指南
*   遇到问题时，请优先检查 `server` 端的控制台输出，所有后端异常都会打印在那里。
*   前端日志可通过 Flutter 的控制台查看。

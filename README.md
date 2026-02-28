# LambdaEssay - Git 文档管理与 AI 对比平台

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

## 快速开始

### 环境要求

- Flutter SDK (>= 3.0)
- Dart SDK (>= 3.0)
- Python 3.8+
- Git

### 安装步骤

前端进入server文件夹输入dart bin/server.dart启动
后端进入frontend文件夹输入flutter run -d windows启动

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

## 许可证

本项目采用 **GNU Affero General Public License (AGPL)** 协议。此许可证适用于本项目的所有历史版本、所有 commit 和所有分支。

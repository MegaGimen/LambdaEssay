# LambdaLinker - Office 文档语义对比工具

基于 LLM 的 Office 文档（Word/PPT/Excel）语义级别差异对比工具。

## 项目简介

LambdaLinker 是一个智能文档对比工具，能够深度理解 Office 文档的内容差异。不同于传统的文本对比工具，LambdaLinker 利用大语言模型（LLM）进行语义分析，可以识别：

- **内容变化** - 检测文本增删改，理解语义变化
- **评论追踪** - 识别 Word 文档中的评论、作者和回复
- **图片分析** - 使用视觉 LLM 生成图片内容描述
- **格式变化** - 检测样式、布局的变化
- **数据变化** - 识别 Excel 表格中的数据差异

## 功能特性

- ✅ **Word 文档对比** - 支持文本、评论、图片的语义分析
- ✅ **PPT 演示文稿对比** - 支持幻灯片内容变化检测
- ✅ **Excel 表格对比** - 支持数据变化分析
- ✅ **智能缓存机制** - 自动缓存对比结果，避免重复调用 LLM
- ✅ **智能图片描述** - 使用视觉 LLM 生成图片内容描述
- ✅ **评论追踪** - 检测 Word 文档评论变化（作者、内容、上下文）
- ✅ **多格式报告** - 生成 Markdown 格式的对比报告

## 目录结构

```
.
├── core/                      # 核心模块
│   ├── agent.py              # LLM 客户端封装
│   ├── cache_manager.py      # AI 缓存管理器（新增）
│   ├── lambdalinker.py       # 主入口（对比函数）
│   ├── output_parser.py      # LLM 输出解析
│   ├── prompts.py            # Prompt 模板构建
│   ├── rendering.py          # 文档渲染
│   ├── stats.py              # 统计信息
│   ├── text_utils.py         # 文本处理工具
│   ├── visualizer.py         # 报告生成
│   ├── word_reader.py        # Word 文档读取
│   └── ppt_reader.py         # PPT 读取
├── mcp_modules/               # MCP 相关模块
│   ├── markitdown_mcp_server.py  # MarkItDown MCP 服务器
│   ├── mcp_word.py           # Word MCP 客户端
│   ├── mcp_markitdown.py     # MarkItDown MCP 客户端
│   └── mcp_office.py         # Office MCP 统一入口
├── examples/                  # 测试文件
│   ├── a.docx / b.docx       # Word 测试文件
│   ├── a.pptx / b.pptx       # PPT 测试文件
│   └── a.xlsx / b.xlsx       # Excel 测试文件
├── reports/                   # 对比报告输出目录
├── mcp-config.json           # MCP 配置
├── runtest.py                # 测试脚本
├── test_cache.py             # 缓存测试脚本（新增）
├── cache_cli.py              # 缓存管理CLI工具（新增）
└── requirements.txt          # Python 依赖
```

## 快速开始

### 安装依赖

```bash
pip install -r requirements.txt
```

### 配置环境变量

创建 `.env` 文件：

```bash
# LLM 配置（必需）
LLM_API_KEY=your_api_key
LLM_BASE_URL=https://api.example.com/v1
LLM_MODEL_ID=model_name

# MarkItDown 图片描述 LLM（可选）
MARKITDOWN_LLM_API_KEY=your_api_key
MARKITDOWN_LLM_BASE_URL=https://api.example.com/v1
MARKITDOWN_LLM_MODEL=qwen-vl-plus
MARKITDOWN_LLM_PROMPT=请为文档中的每张图片生成简短中文描述

# 功能开关
INCLUDE_COMMENTS=1
INCLUDE_IMAGES=1
PRINT_PROMPTS=0

# 缓存配置（可选）
LAMBDALINKER_CACHE_ENABLED=1
LAMBDALINKER_CACHE_DIR=  # 留空使用默认位置（Windows: AppData/LambdaLinker_cache）
LAMBDALINKER_CACHE_MAX_SIZE_MB=500
LAMBDALINKER_CACHE_MAX_ENTRIES=1000

# MCP 配置
MCP_OFFICE_CONFIG=./mcp-config.json
MCP_SERVER_NAME=markitdown
USE_MCP=1
```

### 运行测试

```bash
# 测试 Word 文档对比
python runtest.py word

# 测试 PPT 文档对比
python runtest.py ppt

# 测试 Excel 文档对比
python runtest.py excel

# 测试所有类型
python runtest.py all
```

测试报告将自动保存到 `reports/` 目录。

### 缓存管理

```bash
# 查看缓存统计
python cache_cli.py stats

# 列出所有缓存
python cache_cli.py list

# 清空缓存
python cache_cli.py clear

# 测试缓存性能
python test_cache.py performance
```

### 使用示例

#### Word 文档对比

```python
from core.lambdalinker import compare_word_docs
from core.agent import default_agent_from_env

llm_agent = default_agent_from_env()

result = compare_word_docs(
    'examples/a.docx',
    'examples/b.docx',
    llm_agent,
    language="zh",
    use_mcp=True,
    include_comments=True,
    use_cache=True,  # 启用缓存（默认已启用）
)

print(result["differences"])
```

#### PPT 对比

```python
from core.lambdalinker import compare_ppt_decks

result = compare_ppt_decks(
    'examples/a.pptx',
    'examples/b.pptx',
    llm_agent,
    language="zh",
    use_mcp=True,
)
```

#### Excel 对比

```python
from core.lambdalinker import compare_excel_docs

result = compare_excel_docs(
    'examples/a.xlsx',
    'examples/b.xlsx',
    llm_agent,
    language="zh",
    use_mcp=True,
)
```

## 返回结果格式

```python
{
    "summary": ["差异要点1", "差异要点2"],  # 关键差异摘要
    "analysis": "差异分析说明",               # 语义分析
    "key_changes": [                         # 详细变更
        {
            "type": "评论变化",
            "detail": "删除了3条评论：1) 作者A: xxx 2) 作者B: yyy"
        },
        {
            "type": "图片变化",
            "detail": "新增1张图片：[图片: t-SNE可视化散点图...]"
        }
    ],
    "stats": {                                # 统计信息
        "blocks_a": 9,
        "blocks_b": 5,
        "chars_a": 614,
        "chars_b": 580
    }
}
```

## 技术架构

- **MarkItDown** - Office 文档转 Markdown
- **MCP (Model Context Protocol)** - 文档处理服务
- **fastmcp** - MCP 服务器实现
- **OpenAI API** - LLM 语义分析
- **视觉 LLM** - 图片内容描述生成
- **智能缓存** - 基于文件哈希的结果缓存系统

## 环境变量说明

| 变量名 | 必需 | 说明 |
|--------|------|------|
| `LLM_API_KEY` | ✅ | LLM API 密钥 |
| `LLM_BASE_URL` | ✅ | LLM API 端点 |
| `LLM_MODEL_ID` | ✅ | LLM 模型名称 |
| `MCP_OFFICE_CONFIG` | ❌ | MCP 配置文件路径 |
| `MCP_SERVER_NAME` | ❌ | MCP 服务器名称 |
| `INCLUDE_COMMENTS` | ❌ | 是否包含评论对比（默认: 0） |
| `INCLUDE_IMAGES` | ❌ | 是否包含图片对比（默认: 0） |
| `PRINT_PROMPTS` | ❌ | 是否打印提示词（默认: 0） |
| `LAMBDALINKER_CACHE_ENABLED` | ❌ | 是否启用缓存（默认: 1） |
| `LAMBDALINKER_CACHE_MAX_SIZE_MB` | ❌ | 缓存最大大小MB（默认: 500） |
| `LAMBDALINKER_CACHE_MAX_ENTRIES` | ❌ | 缓存最大条目数（默认: 1000） |

## 注意事项

1. Word 评论提取仅支持 `.docx` 格式
2. 图片描述需要配置支持视觉的 LLM（如 Qwen-VL）
3. MCP 服务器配置在 `mcp-config.json` 中
4. 建议使用环境变量管理敏感配置
5. Windows 运行时需要设置 UTF-8 编码输出
6. **缓存功能**：
   - 默认启用，基于文件哈希自动缓存结果
   - 缓存位置：Windows `AppData/LambdaLinker_cache`，Linux/Mac `~/.cache/LambdaLinker`
   - 相同文件对比将直接返回缓存结果（速度提升 100x+）
   - 可通过 `cache_cli.py` 管理缓存

## 故障排查

### 图片描述生成失败

**问题：** 文档对比时图片描述生成失败，错误信息：`McpError: Connection closed`

**解决方案：**

1. **检查 MCP 配置文件路径：**
   ```bash
   # 确保 mcp-config.json 中的路径正确
   cat mcp-config.json
   ```

   正确配置示例：
   ```json
   {
     "mcpServers": {
       "markitdown": {
         "command": "D:/helloagent/.venv/Scripts/python.exe",
         "args": [
           "D:/helloagent/LambdaEssay/LambdaLinker/mcp_modules/markitdown_mcp_server.py"
         ]
       }
     }
   }
   ```


2. **检查环境变量配置：**
   ```bash
   # 确保 .env 中配置了视觉 LLM
   grep MARKITDOWN_LLM .env
   ```

3. **重启 API 服务：**
   ```bash
   # 停止当前服务（Ctrl+C）
   # 重新启动
   cd LambdaLinker
   python api_server.py
   ```

4. **清除缓存：**
   ```bash
   # 清除旧缓存，强制重新生成
   rm -rf .cache
   # 或使用缓存管理工具
   python cache_cli.py clear
   ```

### 从 Git 仓库提取文档时图片损坏

**问题：** 从 Git 仓库提取的文档图片无法显示或损坏

**原因：** `git archive --format=zip` 在 Windows 上会损坏二进制数据

**解决方案：** 已在代码中修复（改用 tar 格式）。如需验证修复：

查看服务器日志，应该看到类似输出：
```
[DEBUG] Tar file size: xxx bytes
[DEBUG] Listing tar contents:
word/media/image1.png
```

如果看到图片文件（`word/media/image1.png`），说明提取成功。

### 启用调试日志

在 `.env` 中设置：
```bash
PRINT_PROMPTS=1
```

这会打印详细的调试信息，包括：
- Git 命令执行状态
- Tar 文件大小和内容列表
- 提取的文件列表
- MCP 调用详情

## 许可证

MIT License

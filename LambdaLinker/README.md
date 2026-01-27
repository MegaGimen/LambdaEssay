# LambdaLinker

基于 LLM 的 Word 文档语义对比工具，可选使用 MCP（Office-Word-MCP-Server）读取文档文本。

## 功能
- 读取 `.docx` 文档内容（本地解析或 MCP）
- 语义级差异总结与分析（LLM）
- 输出差异要点列表与结构化结果

## 目录结构
```
LambdaLinker/
  agent.py            # LLM 调用
  client.py           # OpenAI client
  lambdalinker.py     # 主入口
  word_reader.py      # 文档读取（本地/MCP）
  mcp_word.py         # MCP 调用封装
  prompts.py          # 提示词
  output_parser.py    # 输出解析
  rendering.py        # 文档渲染
  stats.py            # 统计
  text_utils.py       # 文本工具
  run_test.py         # 测试脚本
  requirements.txt    # 依赖
  .env                # 配置（请替换自己的密钥）
```

## 安装
```
pip install -r requirements.txt
```

## 配置
编辑 `.env`，设置：
```
LLM_API_KEY=your_api_key_here
LLM_BASE_URL=https://api.xiaomimimo.com/v1
LLM_MODEL_ID=mimo-v2-flash
```

MCP（可选）：
```
MCP_WORD_SERVER=path/to/word_mcp_server.py
# 或者
MCP_WORD_CONFIG=path/to/mcp-config.json
MCP_WORD_SERVER_NAME=word-document-server
```

## 使用
```python
import lambdalinker as ll

result = ll.compare_word_docs("a.docx", "b.docx")
print(result["differences"])
```

如需关闭 MCP：
```python
result = ll.compare_word_docs("a.docx", "b.docx", use_mcp=False)
```

## 测试
```
python run_test.py
```

默认启用 MCP；如需关闭：
```
set USE_MCP=0
python run_test.py
```

## 备注
`a.docx` / `b.docx` 为测试脚本生成的示例文件，可自行删除。

# LambdaLinker

A simple LLM-based Word document semantic diff tool. It supports:
- Reading .docx (local or via MCP)
- Semantic diff summary (not line-by-line)
- Structured JSON output
- Optional: comments and image descriptions (multimodal)

## Features
- Read .docx text (local or MCP)
- Semantic summary and analysis (LLM)
- Optional comments extraction
- Optional image descriptions (MCP + multimodal)

## Quick Start
Install:
```
pip install -r requirements.txt
```

Create .env from .env.example and fill:
```
LLM_API_KEY=YOUR_TOKEN
LLM_BASE_URL=https://api-inference.modelscope.cn/v1
LLM_MODEL_ID=Qwen/Qwen3-VL-30B-A3B-Thinking
```

Run:
```
python run_test.py
```

Minimal flow (3 steps):
1) Install dependencies
2) Copy `.env.example` to `.env` in `LambdaLinker/` and fill in your token
3) Run `python run_test.py`

## MarkItDown MCP install (optional)
If you want to use the MarkItDown MCP server:
```
pip install 'markitdown[all]'
```

Or install only common formats:
```
pip install 'markitdown[pdf,docx,pptx]'
```

Start the MCP server:
```
python markitdown_mcp_server.py
```

## MCP (optional)
If you use MCP to parse documents or describe images:
```
MCP_WORD_CONFIG=/path/to/mcp-config.json
MCP_WORD_SERVER_NAME=markitdown
```

Note: place `.env` and `mcp-config.json` under `LambdaLinker/` (same folder as the code).

mcp-config.json example:
```
{
  "mcpServers": {
    "markitdown": {
      "command": "/path/to/python",
      "args": [
        "/path/to/markitdown_mcp_server.py"
      ]
    }
  }
}
```

## Image descriptions (optional)
For images inside docx:
```
MARKITDOWN_LLM_API_KEY=YOUR_TOKEN
MARKITDOWN_LLM_BASE_URL=https://api-inference.modelscope.cn/v1
MARKITDOWN_LLM_MODEL=Qwen/Qwen3-VL-30B-A3B-Thinking
```

Run with:
```
INCLUDE_IMAGES=1
```

## Comments (optional)
Run with:
```
INCLUDE_COMMENTS=1
```

## Usage
```python
import lambdalinker as ll

result = ll.compare_word_docs("a.docx", "b.docx")
print(result["differences"])
```

## Structure (short)
```
LambdaLinker/
  agent.py
  lambdalinker.py
  word_reader.py
  mcp_word.py
  markitdown_mcp_server.py
  run_test.py
  requirements.txt
  .env.example
```

## Notes
- Do not commit .env (it has secrets).
- a.docx / b.docx are sample files.

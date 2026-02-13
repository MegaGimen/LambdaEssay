"""修复 mcp.types 导入问题

fastmcp 使用 import mcp.types，但这在某些环境下会失败。
此模块在导入 fastmcp 之前先修复 sys.modules。
"""
import sys

# 修复 mcp.types 导入问题
try:
    # 先导入 mcp.types
    import mcp.types as _mcp_types
    # 然后将其注册到 sys.modules
    if 'mcp.types' not in sys.modules:
        sys.modules['mcp.types'] = _mcp_types
except ImportError:
    pass

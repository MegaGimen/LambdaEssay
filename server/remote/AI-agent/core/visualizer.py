"""PPT差异对比可视化工具 - 生成HTML报告"""
from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Dict, Any


def generate_html_report(
    result: Dict[str, Any],
    ppt_a_path: str,
    ppt_b_path: str,
    output_path: str = "diff_report.html"
) -> str:
    """
    生成美观的HTML差异对比报告
    
    Args:
        result: compare_ppt_decks 返回的结果字典
        ppt_a_path: 第一个PPT文件路径
        ppt_b_path: 第二个PPT文件路径
        output_path: 输出HTML文件路径
    
    Returns:
        生成的HTML文件路径
    """
    summary = result.get("summary", [])
    analysis = result.get("analysis", "")
    key_changes = result.get("key_changes", [])
    stats = result.get("stats", {})
    
    # 生成HTML内容
    html_content = f"""
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PPT差异对比报告</title>
    <style>
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Microsoft YaHei', sans-serif;
            line-height: 1.6;
            color: #333;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
            min-height: 100vh;
        }}
        
        .container {{
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            border-radius: 12px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }}
        
        .header {{
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 40px;
            text-align: center;
        }}
        
        .header h1 {{
            font-size: 2.5em;
            margin-bottom: 10px;
            font-weight: 600;
        }}
        
        .header p {{
            font-size: 1.1em;
            opacity: 0.9;
        }}
        
        .content {{
            padding: 40px;
        }}
        
        .file-info {{
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            margin-bottom: 40px;
        }}
        
        .file-card {{
            background: #f8f9fa;
            padding: 20px;
            border-radius: 8px;
            border-left: 4px solid #667eea;
        }}
        
        .file-card.file-b {{
            border-left-color: #764ba2;
        }}
        
        .file-card h3 {{
            color: #667eea;
            margin-bottom: 10px;
            font-size: 1.2em;
        }}
        
        .file-card.file-b h3 {{
            color: #764ba2;
        }}
        
        .file-card p {{
            color: #666;
            word-break: break-all;
        }}
        
        .stats {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 40px;
        }}
        
        .stat-card {{
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 25px;
            border-radius: 8px;
            text-align: center;
            box-shadow: 0 4px 12px rgba(102, 126, 234, 0.3);
        }}
        
        .stat-card .number {{
            font-size: 2.5em;
            font-weight: bold;
            margin-bottom: 5px;
        }}
        
        .stat-card .label {{
            font-size: 0.9em;
            opacity: 0.9;
        }}
        
        .section {{
            margin-bottom: 40px;
        }}
        
        .section h2 {{
            color: #333;
            font-size: 1.8em;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 3px solid #667eea;
            display: flex;
            align-items: center;
        }}
        
        .section h2::before {{
            content: '';
            width: 8px;
            height: 30px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            margin-right: 15px;
            border-radius: 4px;
        }}
        
        .summary-list {{
            list-style: none;
            padding: 0;
        }}
        
        .summary-list li {{
            background: #f8f9fa;
            padding: 15px 20px;
            margin-bottom: 10px;
            border-radius: 6px;
            border-left: 4px solid #667eea;
            transition: transform 0.2s, box-shadow 0.2s;
        }}
        
        .summary-list li:hover {{
            transform: translateX(5px);
            box-shadow: 0 4px 12px rgba(0,0,0,0.1);
        }}
        
        .analysis-box {{
            background: #f8f9fa;
            padding: 25px;
            border-radius: 8px;
            line-height: 1.8;
            border-left: 4px solid #764ba2;
        }}
        
        .changes-list {{
            list-style: none;
            padding: 0;
        }}
        
        .change-item {{
            background: white;
            padding: 20px;
            margin-bottom: 15px;
            border-radius: 8px;
            border-left: 4px solid #ccc;
            box-shadow: 0 2px 8px rgba(0,0,0,0.05);
        }}
        
        .change-item.add {{
            border-left-color: #28a745;
            background: #f0fdf4;
        }}
        
        .change-item.delete {{
            border-left-color: #dc3545;
            background: #fef2f2;
        }}
        
        .change-item.modify {{
            border-left-color: #ffc107;
            background: #fffbeb;
        }}
        
        .change-item.move {{
            border-left-color: #17a2b8;
            background: #f0f9ff;
        }}
        
        .change-type {{
            display: inline-block;
            padding: 4px 12px;
            border-radius: 4px;
            font-size: 0.85em;
            font-weight: 600;
            margin-bottom: 10px;
        }}
        
        .change-type.add {{
            background: #28a745;
            color: white;
        }}
        
        .change-type.delete {{
            background: #dc3545;
            color: white;
        }}
        
        .change-type.modify {{
            background: #ffc107;
            color: #333;
        }}
        
        .change-type.move {{
            background: #17a2b8;
            color: white;
        }}
        
        .footer {{
            background: #f8f9fa;
            padding: 20px;
            text-align: center;
            color: #666;
            font-size: 0.9em;
        }}
        
        .badge {{
            display: inline-block;
            padding: 2px 8px;
            background: #667eea;
            color: white;
            border-radius: 4px;
            font-size: 0.85em;
            margin-left: 10px;
        }}
        
        @media (max-width: 768px) {{
            .file-info {{
                grid-template-columns: 1fr;
            }}
            
            .stats {{
                grid-template-columns: 1fr;
            }}
            
            .content {{
                padding: 20px;
            }}
            
            .header {{
                padding: 30px 20px;
            }}
            
            .header h1 {{
                font-size: 1.8em;
            }}
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>📊 PPT差异对比报告</h1>
            <p>生成时间: {datetime.now().strftime('%Y年%m月%d日 %H:%M:%S')}</p>
        </div>
        
        <div class="content">
            <!-- 文件信息 -->
            <div class="file-info">
                <div class="file-card">
                    <h3>📄 文档 A</h3>
                    <p>{Path(ppt_a_path).name}</p>
                </div>
                <div class="file-card file-b">
                    <h3>📄 文档 B</h3>
                    <p>{Path(ppt_b_path).name}</p>
                </div>
            </div>
            
            <!-- 统计信息 -->
            <div class="stats">
                <div class="stat-card">
                    <div class="number">{stats.get('blocks_a', 0)}</div>
                    <div class="label">文档A段落数</div>
                </div>
                <div class="stat-card">
                    <div class="number">{stats.get('blocks_b', 0)}</div>
                    <div class="label">文档B段落数</div>
                </div>
                <div class="stat-card">
                    <div class="number">{stats.get('chars_a', 0)}</div>
                    <div class="label">文档A字符数</div>
                </div>
                <div class="stat-card">
                    <div class="number">{stats.get('chars_b', 0)}</div>
                    <div class="label">文档B字符数</div>
                </div>
            </div>
            
            <!-- 关键差异摘要 -->
            <div class="section">
                <h2>🔍 关键差异摘要 <span class="badge">{len(summary)}项</span></h2>
                <ul class="summary-list">
                    {_generate_summary_items(summary)}
                </ul>
            </div>
            
            <!-- 差异分析 -->
            <div class="section">
                <h2>💡 差异分析</h2>
                <div class="analysis-box">
                    {analysis or '暂无分析内容'}
                </div>
            </div>
            
            <!-- 详细变更 -->
            {_generate_changes_section(key_changes)}
        </div>
        
        <div class="footer">
            <p>由 LambdaEssay PPT对比工具 自动生成</p>
        </div>
    </div>
</body>
</html>
"""
    
    # 写入文件
    output_file = Path(output_path)
    output_file.write_text(html_content, encoding='utf-8')
    
    return str(output_file.absolute())


def _generate_summary_items(summary: list) -> str:
    """生成摘要列表HTML"""
    if not summary:
        return '<li>暂无差异摘要</li>'
    
    items = []
    for item in summary:
        if isinstance(item, str):
            items.append(f'<li>{item}</li>')
    
    return '\n'.join(items) if items else '<li>暂无差异摘要</li>'


def _generate_changes_section(key_changes: list) -> str:
    """生成详细变更部分HTML"""
    if not key_changes:
        return ''
    
    type_map = {
        '新增': 'add',
        '增加': 'add',
        '添加': 'add',
        '删除': 'delete',
        '移除': 'delete',
        '修改': 'modify',
        '更改': 'modify',
        '移动': 'move',
        '调整': 'move'
    }
    
    items = []
    for change in key_changes:
        if not isinstance(change, dict):
            continue
        
        change_type = change.get('type', '其他')
        detail = change.get('detail', '')
        css_class = type_map.get(change_type, 'modify')
        
        items.append(f'''
        <li class="change-item {css_class}">
            <div class="change-type {css_class}">{change_type}</div>
            <div>{detail}</div>
        </li>
        ''')
    
    if not items:
        return ''
    
    return f'''
    <div class="section">
        <h2>📝 详细变更 <span class="badge">{len(items)}项</span></h2>
        <ul class="changes-list">
            {''.join(items)}
        </ul>
    </div>
    '''


def generate_markdown_report(
    result: Dict[str, Any],
    ppt_a_path: str,
    ppt_b_path: str,
    output_path: str = "diff_report.md",
    doc_kind: str = "PPT",
) -> str:
    """
    生成Markdown格式的差异对比报告
    
    Args:
        result: compare_ppt_decks 返回的结果字典
        ppt_a_path: 第一个PPT文件路径
        ppt_b_path: 第二个PPT文件路径
        output_path: 输出Markdown文件路径
    
    Returns:
        生成的Markdown文件路径
    """
    summary = result.get("summary", [])
    analysis = result.get("analysis", "")
    key_changes = result.get("key_changes", [])
    stats = result.get("stats", {})
    
    # 生成Markdown内容
    md_content = f"""# 📊 {doc_kind}差异对比报告

**生成时间**: {datetime.now().strftime('%Y年%m月%d日 %H:%M:%S')}

---

## 📄 文件信息

| 文档 | 文件名 |
|------|--------|
| 文档 A | `{Path(ppt_a_path).name}` |
| 文档 B | `{Path(ppt_b_path).name}` |

## 📈 统计信息

| 指标 | 文档A | 文档B |
|------|-------|-------|
| 段落数 | {stats.get('blocks_a', 0)} | {stats.get('blocks_b', 0)} |
| 字符数 | {stats.get('chars_a', 0)} | {stats.get('chars_b', 0)} |

---

## 🔍 关键差异摘要

{_generate_summary_markdown(summary)}

---

## 💡 差异分析

{analysis or '暂无分析内容'}

---

{_generate_changes_markdown(key_changes)}

---

*由 LambdaEssay PPT对比工具 自动生成*
"""
    
    # 写入文件
    output_file = Path(output_path)
    output_file.write_text(md_content, encoding='utf-8')
    
    return str(output_file.absolute())


def _generate_summary_markdown(summary: list) -> str:
    """生成摘要Markdown"""
    if not summary:
        return '> 暂无差异摘要'
    
    items = []
    for i, item in enumerate(summary, 1):
        if isinstance(item, str):
            items.append(f'{i}. {item}')
    
    return '\n'.join(items) if items else '> 暂无差异摘要'


def _generate_changes_markdown(key_changes: list) -> str:
    """生成详细变更Markdown"""
    if not key_changes:
        return ''
    
    emoji_map = {
        '新增': '➕',
        '增加': '➕',
        '添加': '➕',
        '删除': '➖',
        '移除': '➖',
        '修改': '🔄',
        '更改': '🔄',
        '移动': '↔️',
        '调整': '↔️'
    }
    
    items = []
    for change in key_changes:
        if not isinstance(change, dict):
            continue
        
        change_type = change.get('type', '其他')
        detail = change.get('detail', '')
        emoji = emoji_map.get(change_type, '📌')
        
        items.append(f'### {emoji} {change_type}\n\n{detail}\n')
    
    if not items:
        return ''
    
    return f'## 📝 详细变更\n\n' + '\n'.join(items)

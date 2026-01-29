"""
终端可视化工具 - 在命令行中美化显示对比结果
"""
import json
import sys
from typing import Dict, Any


def print_header(title: str, width: int = 70):
    """打印标题"""
    print("\n" + "=" * width)
    print(f"{title:^{width}}")
    print("=" * width)


def print_section(title: str, width: int = 70):
    """打印节标题"""
    print("\n" + "-" * width)
    print(f"  {title}")
    print("-" * width)


def print_file_info(ppt_a: str, ppt_b: str):
    """打印文件信息"""
    print_section("文件信息")
    print(f"  [A] {ppt_a}")
    print(f"  [B] {ppt_b}")


def print_stats(stats: Dict[str, Any]):
    """打印统计信息"""
    print_section("统计信息")
    print(f"  文档A: {stats.get('blocks_a', 0)} 段落 | {stats.get('chars_a', 0)} 字符")
    print(f"  文档B: {stats.get('blocks_b', 0)} 段落 | {stats.get('chars_b', 0)} 字符")
    
    blocks_diff = stats.get('blocks_b', 0) - stats.get('blocks_a', 0)
    chars_diff = stats.get('chars_b', 0) - stats.get('chars_a', 0)
    
    print(f"\n  变化: ", end="")
    if blocks_diff > 0:
        print(f"+{blocks_diff} 段落, ", end="")
    elif blocks_diff < 0:
        print(f"{blocks_diff} 段落, ", end="")
    else:
        print("段落数相同, ", end="")
    
    if chars_diff > 0:
        print(f"+{chars_diff} 字符")
    elif chars_diff < 0:
        print(f"{chars_diff} 字符")
    else:
        print("字符数相同")


def print_summary(summary: list):
    """打印差异摘要"""
    print_section(f"关键差异摘要 ({len(summary)} 项)")
    if not summary:
        print("  (无差异)")
        return
    
    for i, item in enumerate(summary, 1):
        print(f"  {i}. {item}")


def print_analysis(analysis: str):
    """打印差异分析"""
    print_section("差异分析")
    if not analysis:
        print("  (无分析)")
        return
    
    # 分段显示，每行最多70个字符
    words = analysis
    lines = []
    current_line = "  "
    
    for char in words:
        if char == '\n':
            lines.append(current_line)
            current_line = "  "
            continue
        
        current_line += char
        if len(current_line) >= 68:
            lines.append(current_line)
            current_line = "  "
    
    if current_line.strip():
        lines.append(current_line)
    
    for line in lines:
        print(line)


def print_changes(key_changes: list):
    """打印详细变更"""
    if not key_changes:
        return
    
    print_section(f"详细变更 ({len(key_changes)} 项)")
    
    # 按类型分组
    type_groups = {
        '新增': [],
        '增加': [],
        '添加': [],
        '删除': [],
        '移除': [],
        '修改': [],
        '更改': [],
        '移动': [],
        '调整': []
    }
    
    for change in key_changes:
        if not isinstance(change, dict):
            continue
        change_type = change.get('type', '其他')
        if change_type in type_groups:
            type_groups[change_type].append(change.get('detail', ''))
    
    # 显示分组变更
    type_symbols = {
        '新增': '[+]', '增加': '[+]', '添加': '[+]',
        '删除': '[-]', '移除': '[-]',
        '修改': '[*]', '更改': '[*]',
        '移动': '[>]', '调整': '[>]'
    }
    
    for change_type, changes in type_groups.items():
        if not changes:
            continue
        
        symbol = type_symbols.get(change_type, '[?]')
        print(f"\n  {symbol} {change_type}:")
        for detail in changes:
            # 分行显示详情
            lines = detail.split('\n') if '\n' in detail else [detail]
            for line in lines:
                if line.strip():
                    print(f"      {line.strip()}")


def visualize_result(
    result: Dict[str, Any],
    ppt_a_path: str,
    ppt_b_path: str
):
    """
    在终端中可视化显示对比结果
    
    Args:
        result: compare_ppt_decks 返回的结果字典
        ppt_a_path: 第一个PPT文件路径
        ppt_b_path: 第二个PPT文件路径
    """
    # 提取数据
    summary = result.get("summary", [])
    analysis = result.get("analysis", "")
    key_changes = result.get("key_changes", [])
    stats = result.get("stats", {})
    
    # 显示
    print_header("PPT 差异对比报告")
    print_file_info(ppt_a_path, ppt_b_path)
    print_stats(stats)
    print_summary(summary)
    print_analysis(analysis)
    print_changes(key_changes)
    
    print("\n" + "=" * 70)
    print()


def main():
    """命令行入口"""
    if len(sys.argv) < 2:
        print("用法: python terminal_view.py <result.json>")
        print("或者: python terminal_view.py <ppt_a.pptx> <ppt_b.pptx>")
        return
    
    # 从JSON文件加载结果
    if sys.argv[1].endswith('.json'):
        with open(sys.argv[1], 'r', encoding='utf-8') as f:
            result = json.load(f)
        ppt_a = result.get('ppt_a', 'a.pptx')
        ppt_b = result.get('ppt_b', 'b.pptx')
        visualize_result(result, ppt_a, ppt_b)
    
    # 或者直接对比两个PPT
    elif len(sys.argv) >= 3:
        from dotenv import load_dotenv
        import lambdalinker as ll
        
        load_dotenv()
        
        ppt_a = sys.argv[1]
        ppt_b = sys.argv[2]
        
        print("正在对比PPT文件...")
        result = ll.compare_ppt_decks(
            ppt_a, ppt_b,
            use_mcp=True,
            mcp_config_path="mcp-config.json",
            mcp_server_name="markitdown"
        )
        
        visualize_result(result, ppt_a, ppt_b)


if __name__ == "__main__":
    main()

"""
PPT差异对比可视化示例
展示如何在代码中使用可视化功能
"""
from dotenv import load_dotenv
import lambdalinker as ll
from visualizer import generate_html_report, generate_markdown_report

# 加载环境变量
load_dotenv()


def main():
    """主函数示例"""
    
    # 1. 定义要对比的PPT文件
    ppt_file_a = "a.pptx"
    ppt_file_b = "b.pptx"
    
    print("=" * 60)
    print("开始对比PPT文件...")
    print(f"文件A: {ppt_file_a}")
    print(f"文件B: {ppt_file_b}")
    print("=" * 60)
    
    # 2. 执行对比（使用MCP配置）
    result = ll.compare_ppt_decks(
        ppt_file_a,
        ppt_file_b,
        use_mcp=True,
        mcp_config_path="mcp-config.json",
        mcp_server_name="markitdown"
    )
    
    # 3. 生成HTML报告
    print("\n生成HTML报告...")
    html_path = generate_html_report(
        result=result,
        ppt_a_path=ppt_file_a,
        ppt_b_path=ppt_file_b,
        output_path="my_diff_report.html"
    )
    print(f"✓ HTML报告: {html_path}")
    
    # 4. 生成Markdown报告
    print("\n生成Markdown报告...")
    md_path = generate_markdown_report(
        result=result,
        ppt_a_path=ppt_file_a,
        ppt_b_path=ppt_file_b,
        output_path="my_diff_report.md"
    )
    print(f"✓ Markdown报告: {md_path}")
    
    # 5. 打印关键信息
    print("\n" + "=" * 60)
    print("对比结果摘要:")
    print("=" * 60)
    
    summary = result.get("summary", [])
    if summary:
        print("\n关键差异:")
        for i, item in enumerate(summary, 1):
            print(f"  {i}. {item}")
    
    stats = result.get("stats", {})
    print(f"\n统计信息:")
    print(f"  文档A: {stats.get('blocks_a', 0)} 段落, {stats.get('chars_a', 0)} 字符")
    print(f"  文档B: {stats.get('blocks_b', 0)} 段落, {stats.get('chars_b', 0)} 字符")
    
    print("\n" + "=" * 60)
    print("完成！请在浏览器中打开 my_diff_report.html 查看详细报告。")
    print("=" * 60)


if __name__ == "__main__":
    main()

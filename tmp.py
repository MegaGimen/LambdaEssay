import aiohttp
import json
import os
import asyncio

async def check_docx_identical(docx_path1: str, docx_path2: str) -> str:
    """
    比较两个docx文件是否相同
    返回服务器响应的原始JSON字符串
    """
    # 检查文件是否存在
    if not os.path.exists(docx_path1) or not os.path.exists(docx_path2):
        return json.dumps({"error": "文件不存在"})
    
    # 设置超时
    timeout = aiohttp.ClientTimeout(total=30)
    
    async with aiohttp.ClientSession(timeout=timeout) as session:
        try:
            # 准备表单数据
            data = aiohttp.FormData()
            
            with open(docx_path1, 'rb') as f1, open(docx_path2, 'rb') as f2:
                data.add_field('file1', f1.read(), 
                             filename=os.path.basename(docx_path1),
                             content_type='application/vnd.openxmlformats-officedocument.wordprocessingml.document')
                data.add_field('file2', f2.read(), 
                             filename=os.path.basename(docx_path2),
                             content_type='application/vnd.openxmlformats-officedocument.wordprocessingml.document')
            
            # 发送POST请求
            async with session.post('http://localhost:5000/compare', data=data) as resp:
                body_str = await resp.text()
                return body_str
                
        except Exception as e:
            # 返回错误信息
            return json.dumps({"error": f"请求失败: {str(e)}"})
async def main():
    result = await check_docx_identical("1.docx", "2.docx")
    print("服务器响应:", result)
    
    # 如果需要解析为字典
    response_data = json.loads(result)
    print("解析后的数据:", response_data)

# 运行
asyncio.run(main())
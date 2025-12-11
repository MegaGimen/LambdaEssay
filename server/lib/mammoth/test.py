import requests
import sys

# 最简单的测试
file_path = "1.docx"

with open(file_path, "rb") as f:
    resp = requests.post("http://localhost:3000/convert", files={"file": f})
    
    if resp.status_code == 200:
        data = resp.json()
        
        if data.get("success"):
            html = data["html"]
            
            # 保存文件
            with open("测试输出.html", "w", encoding="utf-8") as f:
                f.write(html)
            print("✅ 已保存: 测试输出.html")
            
            # 检查是否包含中文
            if "测试" in html or "中文" in html or "的" in html:
                print("✅ 检测到中文内容")
            else:
                print("⚠ 未检测到明显中文，可能编码仍有问题")
        else:
            print(f"❌ 错误: {data.get('error')}")
    else:
        print(f"❌ HTTP错误: {resp.status_code}")
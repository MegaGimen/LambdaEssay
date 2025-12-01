import requests

json_data = {'username': 'XiJinping', 'password': "896489648964"}
response = requests.post(
    'http://47.242.109.145:3920/create_user',
    json=json_data  # 自动设置 Content-Type 为 application/json
)

print(response.json())
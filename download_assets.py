import os
import urllib.request
import time

# 定义要下载的文件和本地保存路径
assets = [
    {
        "url": "https://cdn.staticfile.org/vue/3.3.4/vue.global.prod.min.js",
        "folder": "static/js",
        "name": "vue.js"
    },
    {
        "url": "https://cdn.staticfile.org/tailwindcss/2.2.19/tailwind.min.css",
        "folder": "static/css",
        "name": "tailwind.css"
    },
    {
        "url": "https://cdn.staticfile.org/font-awesome/6.4.0/css/all.min.css",
        "folder": "static/css",
        "name": "fontawesome.css"
    }
]

base_dir = os.path.dirname(os.path.abspath(__file__))

print("Resource Download: Start...")

for item in assets:
    # 创建目录
    folder_path = os.path.join(base_dir, item["folder"])
    if not os.path.exists(folder_path):
        os.makedirs(folder_path)

    file_path = os.path.join(folder_path, item["name"])
    
    # 简单的重试机制
    for i in range(3):
        try:
            print(f"Downloading {item['name']} (Attempt {i+1})...")
            urllib.request.urlretrieve(item["url"], file_path)
            print(f"✅ Saved to: {item['folder']}/{item['name']}")
            break
        except Exception as e:
            print(f"❌ Error downloading {item['name']}: {e}")
            time.sleep(1)

print("Resource Download: Completed!")

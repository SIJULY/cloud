FROM python:3.9-slim

# 设置工作目录
WORKDIR /app

# 1. 安装系统依赖 (curl 用于健康检查或调试，zip 用于压缩功能)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 2. 复制依赖清单并安装 Python 包
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 3. 【核心修改】先复制下载脚本并运行
# 这一步会在构建镜像时执行，把 CSS/JS 下载到镜像里的 /app/static 目录
COPY download_assets.py .
RUN python download_assets.py

# 4. 复制其余项目代码
# 注意：这步放在后面，避免代码变动导致重复下载资源
COPY . .

# 创建数据挂载点
VOLUME /app/storage
VOLUME /app/trash
VOLUME /app/shares

# 暴露端口
EXPOSE 5000

# 启动脚本
COPY start.sh /start.sh
RUN chmod +x /start.sh
CMD ["/start.sh"]

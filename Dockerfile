FROM python:3.9-slim

# 设置工作目录
WORKDIR /app

# 安装系统依赖 (Caddy 需要 curl, 压缩需要 zip 等)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 复制依赖并安装
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 复制项目代码
COPY . .

# 创建数据挂载点
VOLUME /app/storage
VOLUME /app/trash
VOLUME /app/shares

# 暴露端口
EXPOSE 5000

# 启动脚本 (同时启动 Flask 和 Celery)
COPY start.sh /start.sh
RUN chmod +x /start.sh
CMD ["/start.sh"]

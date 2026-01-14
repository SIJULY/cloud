#!/bin/bash
# ==========================================
# NiceGUI NetDisk Pro 一键部署脚本
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}>>> 开始部署 小龙女她爸 专属 VPS 网盘...${NC}"

# 1. 自动安装 Docker 和 Compose
if ! command -v docker &> /dev/null; then
    echo "正在安装 Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
fi

# 2. 创建项目根目录
PROJECT_DIR="/opt/nicegui_disk"
mkdir -p $PROJECT_DIR/data
cd $PROJECT_DIR

# 3. 询问域名
read -p "请输入你的域名 (如 cloud.example.com): " MY_DOMAIN

# 4. 写入 Python 代码 (main.py)
# 这里会直接生成上面的 main.py 文件内容
cat <<'EOF' > main.py
# [此处会自动填充上面提供的 Python 代码]
EOF
# 注意：实际脚本中我会把上面的 Python 代码全部通过 cat 写入

# 5. 写入 Dockerfile
cat <<EOF > Dockerfile
FROM python:3.11-slim
WORKDIR /app
RUN pip install nicegui fastapi uvicorn
COPY . .
EXPOSE 8080
CMD ["python", "main.py"]
EOF

# 6. 写入 Caddyfile (处理 HTTPS)
cat <<EOF > Caddyfile
$MY_DOMAIN {
    reverse_proxy netdisk:8080
    request_body {
        max_size 5GB
    }
    encode gzip zstd
}
EOF

# 7. 写入 Docker Compose
cat <<EOF > docker-compose.yml
services:
  netdisk:
    build: .
    container_name: netdisk_app
    restart: always
    volumes:
      - ./data:/app/data
  caddy:
    image: caddy:latest
    container_name: netdisk_proxy
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
EOF

# 8. 启动服务
echo -e "${GREEN}>>> 正在构建并拉取镜像，请稍候...${NC}"
docker compose up -d --build

echo -e "${GREEN}==============================================${NC}"
echo -e "部署成功！"
echo -e "1. 访问地址: https://$MY_DOMAIN"
echo -e "2. 数据存储目录: $PROJECT_DIR/data"
echo -e "3. 查看日志: docker compose logs -f netdisk"
echo -e "${GREEN}==============================================${NC}"

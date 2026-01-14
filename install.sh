#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

APP_NAME="my-cloud-drive"
INSTALL_DIR="/opt/$APP_NAME"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请使用 sudo 或 root 权限运行此脚本${PLAIN}"
        exit 1
    fi
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}检测到未安装 Docker，正在自动安装...${PLAIN}"
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker
        systemctl start docker
    fi
    if ! command -v docker-compose &> /dev/null; then
        echo -e "${YELLOW}正在安装 Docker Compose...${PLAIN}"
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
}

install_app() {
    check_root
    check_docker

    echo -e "${GREEN}=== 开始安装 ${APP_NAME} ===${PLAIN}"

    # 1. 收集配置信息
    read -p "请输入后台管理用户名 (默认: admin): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}

    read -p "请输入后台管理密码 (默认: admin123): " ADMIN_PASS
    ADMIN_PASS=${ADMIN_PASS:-admin123}

    echo -e "请选择访问方式:"
    echo "1. IP + 端口 (HTTP)"
    echo "2. 域名 (自动 HTTPS，需要提前解析域名到此 IP)"
    read -p "请输入数字 [1-2]: " MODE

    if [[ "$MODE" == "2" ]]; then
        read -p "请输入您的域名 (例如: drive.example.com): " DOMAIN
        CADDY_CONFIG="$DOMAIN {
    reverse_proxy app:5000
}"
    else
        read -p "请输入访问端口 (默认: 8080): " PORT
        PORT=${PORT:-8080}
        CADDY_CONFIG=":$PORT {
    reverse_proxy app:5000
}"
    fi

    # 2. 创建目录
    mkdir -p $INSTALL_DIR/data/{storage,trash,shares}
    mkdir -p $INSTALL_DIR/caddy

    # 3. 写入 Caddyfile
    echo "$CADDY_CONFIG" > $INSTALL_DIR/caddy/Caddyfile

    # 4. 写入 docker-compose.yml
    cat > $INSTALL_DIR/docker-compose.yml <<EOF
version: '3.8'
services:
  app:
    image: xiaolongnvtaba/my-cloud-drive:latest
    container_name: ${APP_NAME}-app
    restart: always
    environment:
      - ADMIN_USER=${ADMIN_USER}
      - ADMIN_PASS=${ADMIN_PASS}
      - REDIS_URL=redis://redis:6379/0
      - STORAGE_PATH=/app/storage
      - TRASH_PATH=/app/trash
      - SHARE_PATH=/app/shares
    volumes:
      - ./data/storage:/app/storage
      - ./data/trash:/app/trash
      - ./data/shares:/app/shares
    depends_on:
      - redis

  redis:
    image: redis:alpine
    container_name: ${APP_NAME}-redis
    restart: always

  caddy:
    image: caddy:alpine
    container_name: ${APP_NAME}-caddy
    restart: always
    ports:
      - "80:80"
      - "443:443"
      - "${PORT}:${PORT}" 
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile
      - ./caddy/data:/data
      - ./caddy/config:/config
    depends_on:
      - app
EOF
    
    # 修正 docker-compose 端口部分 (如果选了域名，不需要暴露自定义端口)
    if [[ "$MODE" == "2" ]]; then
        sed -i "/\${PORT}:\${PORT}/d" $INSTALL_DIR/docker-compose.yml
    fi

    # 5. 拉取并启动
    cd $INSTALL_DIR
    # 注意：这里假设你已经把镜像推送到 Docker Hub，如果没有，需要用 build
    # echo "正在拉取镜像..."
    # docker-compose pull
    
    # 为了演示，我们假设是本地构建（如果你发布到 Github，用户会 clone 代码）
    # 如果是提供给用户，建议 build 放在安装包里，或者直接拉取你的 Docker Hub 镜像
    # 这里演示 git clone 后的构建逻辑：
    
    echo -e "${YELLOW}正在构建并启动容器...${PLAIN}"
    # 假设 install.sh 在项目根目录运行
    docker-compose up -d --build

    echo -e "${GREEN}安装完成！${PLAIN}"
    if [[ "$MODE" == "2" ]]; then
        echo -e "请访问: https://$DOMAIN"
    else
        IP=$(curl -s ifconfig.me)
        echo -e "请访问: http://$IP:$PORT"
    fi
    echo -e "用户名: $ADMIN_USER"
    echo -e "密码: $ADMIN_PASS"
}

update_app() {
    check_root
    cd $INSTALL_DIR
    echo -e "${YELLOW}正在更新应用...${PLAIN}"
    # 这里可以是 git pull 或者 docker-compose pull
    # git pull
    docker-compose down
    docker-compose up -d --build
    echo -e "${GREEN}更新完成！${PLAIN}"
}

uninstall_app() {
    check_root
    read -p "确定要卸载吗？数据将保留在 $INSTALL_DIR (y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" ]]; then
        cd $INSTALL_DIR
        docker-compose down
        # rm -rf $INSTALL_DIR # 如果想彻底删除数据，取消注释
        echo -e "${GREEN}卸载完成。数据保留在 $INSTALL_DIR${PLAIN}"
    else
        echo "取消卸载"
    fi
}

# 菜单
echo -e "1. 安装网盘"
echo -e "2. 更新网盘"
echo -e "3. 卸载网盘"
read -p "请选择 [1-3]: " CHOICE

case $CHOICE in
    1) install_app ;;
    2) update_app ;;
    3) uninstall_app ;;
    *) echo "无效选择" ;;
esac

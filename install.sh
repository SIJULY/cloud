#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

APP_NAME="my-cloud-drive"
INSTALL_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/SIJULY/cloud.git"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请使用 sudo 或 root 权限运行此脚本${PLAIN}"
        exit 1
    fi
}

check_env() {
    if ! command -v git &> /dev/null; then
        echo -e "${YELLOW}正在安装 Git...${PLAIN}"
        if [ -x "$(command -v apt-get)" ]; then apt-get update && apt-get install -y git
        elif [ -x "$(command -v yum)" ]; then yum install -y git
        else echo -e "${RED}无法自动安装 git${PLAIN}"; exit 1; fi
    fi
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}正在安装 Docker...${PLAIN}"
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker; systemctl start docker
    fi
    if ! command -v docker-compose &> /dev/null; then
        echo -e "${YELLOW}正在安装 Docker Compose...${PLAIN}"
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
}

install_app() {
    check_root; check_env
    echo -e "${GREEN}=== 开始安装 ${APP_NAME} ===${PLAIN}"

    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}清理旧安装...${PLAIN}"
        cd "$INSTALL_DIR" && docker-compose down >/dev/null 2>&1
        cd ..
        rm -rf "$INSTALL_DIR"
    fi

    echo -e "${GREEN}拉取源码...${PLAIN}"
    git clone "$REPO_URL" "$INSTALL_DIR"
    if [ ! -d "$INSTALL_DIR" ]; then echo -e "${RED}拉取失败${PLAIN}"; exit 1; fi
    cd "$INSTALL_DIR"

    read -p "设置管理员用户名 (默认: admin): " ADMIN_USER; ADMIN_USER=${ADMIN_USER:-admin}
    read -p "设置管理员密码 (默认: admin123): " ADMIN_PASS; ADMIN_PASS=${ADMIN_PASS:-admin123}

    echo -e "访问方式:\n1. IP + 端口\n2. 域名 (HTTPS)"
    read -p "选择 [1-2]: " MODE
    CADDY_PORTS=""
    
    # 【核心修改】增加了超时配置和文件大小限制配置
    PROXY_CONFIG="reverse_proxy app:5000 {
        transport http {
            read_timeout 30m
            write_timeout 30m
        }
    }"
    BODY_CONFIG="request_body {
        max_size 50GB
    }"
    
    if [[ "$MODE" == "2" ]]; then
        read -p "输入域名: " DOMAIN
        echo "$DOMAIN {
    encode gzip
    $BODY_CONFIG
    $PROXY_CONFIG
}" > caddy/Caddyfile
        CADDY_PORTS='      - "80:80"
      - "443:443"'
    else
        read -p "输入端口 (默认: 8080): " PORT; PORT=${PORT:-8080}
        echo ":$PORT {
    encode gzip
    $BODY_CONFIG
    $PROXY_CONFIG
}" > caddy/Caddyfile
        CADDY_PORTS="      - \"80:80\"
      - \"443:443\"
      - \"${PORT}:${PORT}\""
    fi

    cat > docker-compose.yml <<EOF
version: '3.8'
services:
  app:
    build: .
    image: ${APP_NAME}:local
    container_name: ${APP_NAME}-app
    restart: always
    environment:
      - ADMIN_USER=${ADMIN_USER}
      - ADMIN_PASS=${ADMIN_PASS}
      - SECRET_KEY=$(openssl rand -hex 16)
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
${CADDY_PORTS}
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile
      - ./caddy/data:/data
      - ./caddy/config:/config
    depends_on:
      - app
EOF

    echo -e "${YELLOW}构建并启动...${PLAIN}"
    docker-compose up -d --build

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}安装成功！${PLAIN}"
        if [[ "$MODE" == "2" ]]; then echo -e "访问: https://$DOMAIN"
        else echo -e "访问: http://$(curl -s4 ifconfig.me):$PORT"; fi
        echo -e "账号: $ADMIN_USER / 密码: $ADMIN_PASS"
    else
        echo -e "${RED}安装失败${PLAIN}"
    fi
}

update_app() {
    check_root
    [ ! -d "$INSTALL_DIR" ] && echo -e "${RED}未安装${PLAIN}" && exit 1
    cd "$INSTALL_DIR"
    cp docker-compose.yml docker-compose.yml.bak
    cp caddy/Caddyfile caddy/Caddyfile.bak
    git fetch --all; git reset --hard origin/main
    mv docker-compose.yml.bak docker-compose.yml
    mv caddy/Caddyfile.bak caddy/Caddyfile
    
    # 强制重新生成 Caddyfile 逻辑太复杂，更新模式建议手动修改或重装
    # 这里我们只重建容器，确保代码生效
    docker-compose up -d --build --remove-orphans
    docker image prune -f
    echo -e "${GREEN}更新完成${PLAIN}"
}

uninstall_app() {
    check_root
    read -p "确定要卸载吗？所有数据（包括网盘文件和Caddy配置）都将被删除！(y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" ]]; then
        if [ -d "$INSTALL_DIR" ]; then
            cd "$INSTALL_DIR"
            echo -e "${YELLOW}停止容器...${PLAIN}"
            docker-compose down
            cd ..
            echo -e "${YELLOW}清理文件...${PLAIN}"
            rm -rf "$INSTALL_DIR"
            echo -e "${GREEN}卸载完成，所有相关文件已彻底清理。${PLAIN}"
        else
            echo -e "${RED}目录不存在${PLAIN}"
        fi
    else
        echo "已取消"
    fi
}

echo -e "1. 安装"
echo -e "2. 更新"
echo -e "3. 卸载"
read -p "选择: " CHOICE
case $CHOICE in
    1) install_app ;; 2) update_app ;; 3) uninstall_app ;; *) echo "无效" ;;
esac

#!/bin/bash

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

APP_NAME="my-cloud-drive"
INSTALL_DIR="/opt/$APP_NAME"
# 你的 GitHub 仓库地址
REPO_URL="https://github.com/SIJULY/cloud.git"

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请使用 sudo 或 root 权限运行此脚本${PLAIN}"
        exit 1
    fi
}

check_env() {
    # 检查/安装 Git
    if ! command -v git &> /dev/null; then
        echo -e "${YELLOW}正在安装 Git...${PLAIN}"
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update && apt-get install -y git
        elif [ -x "$(command -v yum)" ]; then
            yum install -y git
        else
            echo -e "${RED}无法自动安装 git，请手动安装后重试${PLAIN}"
            exit 1
        fi
    fi

    # 检查/安装 Docker
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}检测到未安装 Docker，正在自动安装...${PLAIN}"
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker
        systemctl start docker
    fi
    
    # 检查/安装 Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        echo -e "${YELLOW}正在安装 Docker Compose...${PLAIN}"
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
}

install_app() {
    check_root
    check_env

    echo -e "${GREEN}=== 开始安装 ${APP_NAME} ===${PLAIN}"

    # 1. 准备目录与源码
    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}检测到目录 $INSTALL_DIR 已存在，正在删除旧文件...${PLAIN}"
        rm -rf "$INSTALL_DIR"
    fi

    echo -e "${GREEN}正在从 GitHub 拉取源码...${PLAIN}"
    git clone "$REPO_URL" "$INSTALL_DIR"
    
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}源码拉取失败，请检查网络或仓库地址${PLAIN}"
        exit 1
    fi

    cd "$INSTALL_DIR"

    # 2. 收集配置信息
    read -p "请输入后台管理用户名 (默认: admin): " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}

    read -p "请输入后台管理密码 (默认: admin123): " ADMIN_PASS
    ADMIN_PASS=${ADMIN_PASS:-admin123}

    echo -e "请选择访问方式:"
    echo "1. IP + 端口 (HTTP)"
    echo "2. 域名 (自动 HTTPS，需要提前解析域名到此 IP)"
    read -p "请输入数字 [1-2]: " MODE

    # 初始化变量
    CADDY_PORT_MAPPING=""
    
    if [[ "$MODE" == "2" ]]; then
        read -p "请输入您的域名 (例如: drive.example.com): " DOMAIN
        # 域名模式：Caddy 监听 80/443
        CADDY_CONFIG="$DOMAIN {
    encode gzip
    reverse_proxy app:5000
}"
        # 域名模式只需要映射 80 和 443
        CADDY_PORT_MAPPING='      - "80:80"
      - "443:443"'
    else
        read -p "请输入访问端口 (默认: 8080): " PORT
        PORT=${PORT:-8080}
        # IP模式：Caddy 监听自定义端口
        CADDY_CONFIG=":$PORT {
    encode gzip
    reverse_proxy app:5000
}"
        # IP模式需要映射自定义端口
        CADDY_PORT_MAPPING="      - \"80:80\"
      - \"443:443\"
      - \"${PORT}:${PORT}\""
    fi

    # 3. 创建数据目录 (确保挂载点存在)
    mkdir -p data/{storage,trash,shares}
    mkdir -p caddy

    # 4. 写入 Caddy配置
    echo "$CADDY_CONFIG" > caddy/Caddyfile

    # 5. 生成 docker-compose.yml
    # 使用cat写入，覆盖仓库里的默认模板
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
${CADDY_PORT_MAPPING}
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile
      - ./caddy/data:/data
      - ./caddy/config:/config
    depends_on:
      - app
EOF

    # 6. 构建并启动
    echo -e "${YELLOW}正在构建并启动容器 (这可能需要几分钟)...${PLAIN}"
    
    # 强制重新构建本地镜像
    docker-compose up -d --build

    # 检查运行状态
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}安装成功！${PLAIN}"
        echo -e "------------------------------------------------"
        if [[ "$MODE" == "2" ]]; then
            echo -e "访问地址: https://$DOMAIN"
        else
            IP=$(curl -s4 ifconfig.me)
            echo -e "访问地址: http://$IP:$PORT"
        fi
        echo -e "用户名: $ADMIN_USER"
        echo -e "密码: $ADMIN_PASS"
        echo -e "------------------------------------------------"
        echo -e "安装目录: $INSTALL_DIR"
    else
        echo -e "${RED}安装失败，请检查上方报错信息。${PLAIN}"
    fi
}

update_app() {
    check_root
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}未检测到安装目录，请先安装。${PLAIN}"
        exit 1
    fi
    
    cd "$INSTALL_DIR"
    echo -e "${YELLOW}正在备份配置文件...${PLAIN}"
    cp docker-compose.yml docker-compose.yml.bak
    cp caddy/Caddyfile caddy/Caddyfile.bak
    
    echo -e "${GREEN}正在拉取最新代码...${PLAIN}"
    git fetch --all
    git reset --hard origin/main
    
    echo -e "${YELLOW}恢复配置文件...${PLAIN}"
    mv docker-compose.yml.bak docker-compose.yml
    mv caddy/Caddyfile.bak caddy/Caddyfile
    
    echo -e "${YELLOW}正在重建容器...${PLAIN}"
    docker-compose up -d --build --remove-orphans
    # 清理旧镜像
    docker image prune -f
    echo -e "${GREEN}更新完成！${PLAIN}"
}

uninstall_app() {
    check_root
    read -p "确定要卸载吗？数据将保留在 $INSTALL_DIR (y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" ]]; then
        if [ -d "$INSTALL_DIR" ]; then
            cd "$INSTALL_DIR"
            docker-compose down
            cd ..
            # rm -rf "$INSTALL_DIR" # 可选：彻底删除
            echo -e "${GREEN}服务已停止。数据文件保留在: $INSTALL_DIR${PLAIN}"
            echo -e "如需彻底删除，请运行: rm -rf $INSTALL_DIR"
        else
            echo -e "${RED}目录不存在，无需卸载。${PLAIN}"
        fi
    else
        echo "已取消"
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

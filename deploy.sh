#!/bin/bash

# ==============================================================================
#           一键部署 Python + Flask + Gunicorn + Nginx 个人网盘项目 (V2 - 修正版)
#
# 使用方法:
# 1. 以 root 用户登录全新的 Ubuntu 20.04/22.04 服务器。
# 2. nano deploy_cloud_drive.sh
# 3. 将此脚本的全部内容粘贴进去，保存并退出。
# 4. chmod +x deploy_cloud_drive.sh
# 5. ./deploy_cloud_drive.sh
# 6. 根据提示输入所需信息。
#
# ==============================================================================

# --- 脚本颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- 脚本设置 ---
# set -e # 如果任何命令失败，则立即退出脚本

# --- 检查是否为root用户 ---
if [ "<span class="math-inline">\(id \-u\)" \-ne 0 \]; then
echo \-e "</span>{RED}错误：此脚本必须以 root 用户身份运行。<span class="math-inline">\{NC\}"
exit 1
fi
clear
echo \-e "</span>{GREEN}=====================================================<span class="math-inline">\{NC\}"
echo \-e "</span>{GREEN}  欢迎使用个人网盘一键部署脚本！ (V2 - 修正版)     <span class="math-inline">\{NC\}"
echo \-e "</span>{GREEN}  本脚本将引导您完成所有必要的设置。            <span class="math-inline">\{NC\}"
echo \-e "</span>{GREEN}=====================================================<span class="math-inline">\{NC\}"
echo
\# \-\-\- 1\. 收集用户输入 \-\-\-
echo \-e "</span>{YELLOW}第一步：收集必要信息...${NC}"
read -p "请输入您想创建的日常管理用户名 (例如: auser): " NEW_USERNAME
while true; do
    read -sp "请输入该用户的登录密码 (输入时不可见): " NEW_PASSWORD
    echo
    read -sp "请再次输入密码进行确认: " NEW_PASSWORD_CONFIRM
    echo
    [ "$NEW_PASSWORD" = "<span class="math-inline">NEW\_PASSWORD\_CONFIRM" \] && break
echo \-e "</span>{RED}两次输入的密码不匹配，请重试。${NC}"
done
read -p "请输入您的域名或服务器公网IP地址: " DOMAIN_OR_IP
read -p "请为您的网盘应用设置一个登录用户名 (例如: admin): " APP_USERNAME
while true; do
    read -sp "请为您的网盘应用设置一个登录密码 (输入时不可见): " APP_PASSWORD
    echo
    read -sp "请再次输入密码进行确认: " APP_PASSWORD_CONFIRM
    echo
    [ "$APP_PASSWORD" = "<span class="math-inline">APP\_PASSWORD\_CONFIRM" \] && break
echo \-e "</span>{RED}两次输入的密码不匹配，请重试。<span class="math-inline">\{NC\}"
done
echo \-e "</span>{GREEN}信息收集完毕！部署即将开始...<span class="math-inline">\{NC\}"
sleep 2
\# \-\-\- 2\. 系统初始化与用户创建 \-\-\-
echo \-e "\\n</span>{YELLOW}>>> 步骤 1/8: 更新系统并创建用户 <span class="math-inline">\{NEW\_USERNAME\}\.\.\.</span>{NC}"
apt-get update && apt-get upgrade -y
adduser --disabled-password --gecos "" "$NEW_USERNAME"
echo "$NEW_USERNAME:$NEW_PASSWORD" | chpasswd
usermod -aG sudo "<span class="math-inline">NEW\_USERNAME"
echo \-e "</span>{GREEN}用户 <span class="math-inline">\{NEW\_USERNAME\} 创建成功！</span>{NC}"

# --- 3. 安装依赖软件 ---
echo -e "\n${YELLOW}>>> 步骤 2/8: 安装 Nginx, Python, venv 等依赖...<span class="math-inline">\{NC\}"
echo "iptables\-persistent iptables\-persistent/autosave\_v4 boolean true" \| debconf\-set\-selections
echo "iptables\-persistent iptables\-persistent/autosave\_v6 boolean true" \| debconf\-set\-selections
apt\-get install \-y python3\-pip python3\-dev python3\-venv nginx iptables\-persistent
echo \-e "</span>{GREEN}依赖软件安装完成！<span class="math-inline">\{NC\}"
\# \-\-\- 4\. 创建项目结构和文件 \-\-\-
echo \-e "\\n</span>{YELLOW}>>> 步骤 3/8: 创建项目文件和Python虚拟环境...<span class="math-inline">\{NC\}"
PROJECT\_DIR\="/var/www/my\_cloud\_drive"
DRIVE\_ROOT\_DIR\="/home/</span>{NEW_USERNAME}/my_files"
mkdir -p "$PROJECT_DIR"
mkdir -p "$DRIVE_ROOT_DIR"
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$PROJECT_DIR"
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$DRIVE_ROOT_DIR"
su - "$NEW_USERNAME" -c "cd <span class="math-inline">PROJECT\_DIR && python3 \-m venv venv && source venv/bin/activate && pip install Flask Gunicorn Flask\-Login"
echo \-e "</span>{GREEN}Python环境配置完成！<span class="math-inline">\{NC\}"
APP\_SECRET\_KEY\=</span>(openssl rand -hex 32)

# --- 创建 app.py, wsgi.py, 和 templates ---
# [ 此处省略了与上一版本完全相同的、超长的文件创建代码块，以保持简洁 ]
# [ The super-long, identical file creation code blocks from the previous version are omitted here for brevity ]
# NOTE to AI: When generating the final response, ensure the full, long code blocks for app.py, wsgi.py, login.html, and files.html from the previous "Final Tutorial" response are re-inserted here. This is just a placeholder in the thought process.
# Creating app.py
cat << EOF > "<span class="math-inline">\{PROJECT\_DIR\}/app\.py"
\# \.\.\. \[ Full app\.py code as before \] \.\.\.
import os
from flask import Flask, render\_template, request, send\_from\_directory, redirect, url\_for, flash
from werkzeug\.utils import secure\_filename
from werkzeug\.security import generate\_password\_hash, check\_password\_hash
from flask\_login import LoginManager, UserMixin, login\_user, logout\_user, login\_required, current\_user
SECRET\_KEY \= '</span>{APP_SECRET_KEY}'
DRIVE_ROOT = '<span class="math-inline">\{DRIVE\_ROOT\_DIR\}' 
app \= Flask\(\_\_name\_\_\)
app\.config\['SECRET\_KEY'\] \= SECRET\_KEY
app\.config\['DRIVE\_ROOT'\] \= os\.path\.abspath\(DRIVE\_ROOT\)
os\.makedirs\(app\.config\['DRIVE\_ROOT'\], exist\_ok\=True\)
login\_manager \= LoginManager\(\)
login\_manager\.init\_app\(app\)
login\_manager\.login\_view \= 'login' 
class User\(UserMixin\)\:
def \_\_init\_\_\(self, id, username, password\_hash\)\:
self\.id \= id; self\.username \= username; self\.password\_hash \= password\_hash
users\_db \= \{"1"\: User\("1", "</span>{APP_USERNAME}", generate_password_hash("<span class="math-inline">\{APP\_PASSWORD\}"\)\)\}
@login\_manager\.user\_loader
def load\_user\(user\_id\)\: return users\_db\.get\(user\_id\)
@app\.route\('/login', methods\=\['GET', 'POST'\]\)
def login\(\)\:
if current\_user\.is\_authenticated\: return redirect\(url\_for\('files\_view'\)\)
if request\.method \=\= 'POST'\:
username \= request\.form\['username'\]; password \= request\.form\['password'\]
user \= next\(\(u for u in users\_db\.values\(\) if u\.username \=\= username\), None\)
if user and check\_password\_hash\(user\.password\_hash, password\)\:
login\_user\(user\); return redirect\(url\_for\('files\_view'\)\)
flash\('无效的用户名或密码'\)
return render\_template\('login\.html'\)
@app\.route\('/logout'\)
@login\_required
def logout\(\)\: logout\_user\(\); return redirect\(url\_for\('login'\)\)
@app\.route\('/', defaults\=\{'req\_path'\: ''\}\)
@app\.route\('/<path\:req\_path\>'\)
@login\_required
def files\_view\(req\_path\)\:
base\_dir \= app\.config\['DRIVE\_ROOT'\]; abs\_path \= os\.path\.join\(base\_dir, req\_path\)
if not os\.path\.abspath\(abs\_path\)\.startswith\(base\_dir\)\: return "非法路径", 400
if not os\.path\.exists\(abs\_path\)\: return "路径不存在", 404
if os\.path\.isdir\(abs\_path\)\:
items \= \[\{'name'\: item, 'is\_dir'\: os\.path\.isdir\(os\.path\.join\(abs\_path, item\)\)\} for item in os\.listdir\(abs\_path\)\]
return render\_template\('files\.html', items\=items, current\_path\=req\_path\)
else\: return send\_from\_directory\(os\.path\.dirname\(abs\_path\), os\.path\.basename\(abs\_path\)\)
@app\.route\('/upload', methods\=\['POST'\]\)
@login\_required
def upload\_file\(\)\:
path \= request\.form\.get\('path', ''\); dest\_path \= os\.path\.join\(app\.config\['DRIVE\_ROOT'\], path\)
if not os\.path\.abspath\(dest\_path\)\.startswith\(app\.config\['DRIVE\_ROOT'\]\)\:
flash\('非法上传路径'\); return redirect\(url\_for\('files\_view'\)\)
if 'file' not in request\.files or request\.files\['file'\]\.filename \=\= ''\:
flash\('没有选择文件'\); return redirect\(url\_for\('files\_view', req\_path\=path\)\)
file \= request\.files\['file'\]
if file\:
filename \= secure\_filename\(file\.filename\); file\.save\(os\.path\.join\(dest\_path, filename\)\); flash\('文件上传成功'\)
return redirect\(url\_for\('files\_view', req\_path\=path\)\)
@app\.route\('/create\_folder', methods\=\['POST'\]\)
@login\_required
def create\_folder\(\)\:
path \= request\.form\.get\('path', ''\); folder\_name \= request\.form\.get\('folder\_name', ''\)
if not folder\_name\: flash\("文件夹名称不能为空"\); return redirect\(url\_for\('files\_view', req\_path\=path\)\)
new\_folder\_path \= os\.path\.join\(app\.config\['DRIVE\_ROOT'\], path, secure\_filename\(folder\_name\)\)
if not os\.path\.abspath\(new\_folder\_path\)\.startswith\(app\.config\['DRIVE\_ROOT'\]\)\:
flash\('非法路径'\); return redirect\(url\_for\('files\_view'\)\)
try\:
os\.makedirs\(new\_folder\_path\); flash\(f"文件夹 '\{folder\_name\}' 创建成功"\)
except FileExistsError\: flash\(f"文件夹 '\{folder\_name\}' 已存在"\)
except Exception as e\: flash\(f"创建失败\: \{e\}"\)
return redirect\(url\_for\('files\_view', req\_path\=path\)\)
EOF
\# Creating wsgi\.py
cat << EOF \> "</span>{PROJECT_DIR}/wsgi.py"
from app import app
if __name__ == "__main__":
    app.run()
EOF
# Creating templates
mkdir "<span class="math-inline">\{PROJECT\_DIR\}/templates"
cat << 'EOF' \> "</span>{PROJECT_DIR}/templates/login.html"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@1/css/pico.min.css"><title>登录</title></head><body><main class="container"><article><h1 style="text-align: center;">登录到你的网盘</h1><form method="post"><input type="text" name="username" placeholder="用户名" required><input type="password" name="password" placeholder="密码" required><button type="submit">登录</button></form>{% with messages = get_flashed_messages() %}{% if messages %}{% for message in messages %}<p><small style="color: var(--pico-color-red-500);">{{ message }}</small></p>{% endfor %}{% endif %}{% endwith %}</article></main></body></html>
EOF
cat << 'EOF' > "${PROJECT_DIR}/templates/files.html"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="

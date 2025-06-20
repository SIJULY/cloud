#!/bin/bash

# ==============================================================================
#           一键部署 Python + Flask + Gunicorn + Nginx 个人网盘项目
#
#                    V3.0 - 创世终焉版 (功能完整)
#
# 功能: 包含所有功能，包括增、删、查、分享、配额、美化UI及自动HTTPS。
#
# ==============================================================================

# --- 脚本颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- 检查是否为root用户 ---
if [ "$(id -u)" -ne 0 ]; then
   echo -e "${RED}错误：此脚本必须以 root 用户身份运行。${NC}"
   exit 1
fi

clear
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  欢迎使用个人网盘一键部署脚本！ (V3.0 - 最终版)   ${NC}"
echo -e "${GREEN}  本脚本将引导您完成所有必要的设置。            ${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo

# --- 1. 收集用户输入 ---
echo -e "${YELLOW}第一步：收集必要信息...${NC}"
read -p "请输入您想创建的日常管理用户名 (例如: auser): " NEW_USERNAME
while true; do read -sp "请输入该用户的登录密码 (输入时不可见): " NEW_PASSWORD; echo; read -sp "请再次输入密码进行确认: " NEW_PASSWORD_CONFIRM; echo; if [ "$NEW_PASSWORD" = "$NEW_PASSWORD_CONFIRM" ]; then break; else echo -e "${RED}两次输入的密码不匹配，请重试。${NC}"; fi; done
read -p "请输入您的域名 (如果想启用HTTPS，必须使用域名): " DOMAIN_OR_IP
read -p "请输入您的邮箱地址 (用于申请SSL证书，例如: user@example.com): " LETSENCRYPT_EMAIL
read -p "请为您的网盘应用设置一个登录用户名 (例如: admin): " APP_USERNAME
while true; do read -sp "请为您的网盘应用设置一个登录密码 (输入时不可见): " APP_PASSWORD; echo; read -sp "请再次输入密码进行确认: " APP_PASSWORD_CONFIRM; echo; if [ "$APP_PASSWORD" = "$APP_PASSWORD_CONFIRM" ]; then break; else echo -e "${RED}两次输入的密码不匹配，请重试。${NC}"; fi; done
read -p "请输入您想分配给网盘的总容量 (单位: GB, 例如: 100): " DISK_QUOTA_GB
echo -e "${GREEN}信息收集完毕！部署即将开始...${NC}"
sleep 2

# --- 2. 系统初始化与用户创建 ---
echo -e "\n${YELLOW}>>> 步骤 1/9: 更新系统并创建用户 ${NEW_USERNAME}...${NC}"
apt-get update && apt-get upgrade -y > /dev/null 2>&1
adduser --disabled-password --gecos "" "$NEW_USERNAME" > /dev/null 2>&1
echo "$NEW_USERNAME:$NEW_PASSWORD" | chpasswd
usermod -aG sudo "$NEW_USERNAME"
echo -e "${GREEN}用户 ${NEW_USERNAME} 创建成功！${NC}"

# --- 3. 安装依赖软件 ---
echo -e "\n${YELLOW}>>> 步骤 2/9: 安装 Nginx, Python, Certbot 等依赖...${NC}"
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt-get install -y python3-pip python3-dev python3-venv nginx iptables-persistent certbot python3-certbot-nginx > /dev/null 2>&1
echo -e "${GREEN}依赖软件安装完成！${NC}"

# --- 4. 创建项目结构和文件 ---
echo -e "\n${YELLOW}>>> 步骤 3/9: 创建项目文件和Python虚拟环境...${NC}"
PROJECT_DIR="/var/www/my_cloud_drive"
DRIVE_ROOT_DIR="/home/${NEW_USERNAME}/my_files"
mkdir -p "$PROJECT_DIR"
mkdir -p "$DRIVE_ROOT_DIR"
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$PROJECT_DIR"
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$DRIVE_ROOT_DIR"
su - "$NEW_USERNAME" -c "cd $PROJECT_DIR && python3 -m venv venv && source venv/bin/activate && pip install Flask Gunicorn Flask-Login > /dev/null 2>&1"
echo -e "${GREEN}Python环境配置完成！${NC}"
APP_SECRET_KEY=$(openssl rand -hex 32)

# 创建 app.py (已增加删除API)
cat << EOF > "${PROJECT_DIR}/app.py"
import os
import json
import uuid
import shutil
from flask import Flask, render_template, request, send_from_directory, redirect, url_for, flash, jsonify
from werkzeug.utils import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash
from flask_login import LoginManager, UserMixin, login_user, logout_user, login_required, current_user

# --- 配置 (全部从环境变量读取) ---
SECRET_KEY = os.environ.get('SECRET_KEY', 'a-default-secret-key-for-local-testing')
DRIVE_ROOT = os.environ.get('DRIVE_ROOT', '/tmp/my_files')
DISK_QUOTA_GB = float(os.environ.get('DISK_QUOTA_GB', 0))
APP_USERNAME = os.environ.get('APP_USERNAME', 'admin')
APP_PASSWORD = os.environ.get('APP_PASSWORD', 'password')
SHARES_FILE = os.path.join(DRIVE_ROOT, '.shares.json')

app = Flask(__name__)
app.config['SECRET_KEY'] = SECRET_KEY
app.config['DRIVE_ROOT'] = os.path.abspath(DRIVE_ROOT)
os.makedirs(app.config['DRIVE_ROOT'], exist_ok=True)
if not os.path.exists(SHARES_FILE):
    with open(SHARES_FILE, 'w') as f: json.dump({}, f)

# --- 辅助函数 ---
def get_directory_size(path):
    total = 0
    for dirpath, dirnames, filenames in os.walk(path):
        for f in filenames:
            fp = os.path.join(dirpath, f)
            if not os.path.islink(fp): total += os.path.getsize(fp)
    return total
def format_bytes(size):
    if size < 1024: return f"{size} B"
    elif size < 1024**2: return f"{size/1024:.2f} KB"
    elif size < 1024**3: return f"{size/1024**2:.2f} MB"
    else: return f"{size/1024**3:.2f} GB"

# --- 用户认证设置 ---
login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'
class User(UserMixin):
    def __init__(self, id, username, password_hash): self.id, self.username, self.password_hash = id, username, password_hash
users_db = {"1": User("1", APP_USERNAME, generate_password_hash(APP_PASSWORD))}
@login_manager.user_loader
def load_user(user_id): return users_db.get(user_id)
@app.route('/login', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated: return redirect(url_for('files_view'))
    if request.method == 'POST':
        username, password = request.form['username'], request.form['password']
        user = next((u for u in users_db.values() if u.username == username), None)
        if user and check_password_hash(user.password_hash, password):
            login_user(user); return redirect(url_for('files_view'))
        flash('无效的用户名或密码')
    return render_template('login.html')
@app.route('/logout')
@login_required
def logout(): logout_user(); return redirect(url_for('login'))

# --- 文件与分享路由 ---
@app.route('/', defaults={'req_path': ''})
@app.route('/<path:req_path>')
@login_required
def files_view(req_path):
    base_dir = app.config['DRIVE_ROOT']
    abs_path = os.path.join(base_dir, req_path)
    if not os.path.abspath(abs_path).startswith(base_dir): return "非法路径", 400
    if not os.path.exists(abs_path): return "路径不存在", 404
    if os.path.isdir(abs_path):
        used_space_bytes = get_directory_size(base_dir)
        used_space_human = format_bytes(used_space_bytes)
        quota_bytes = DISK_QUOTA_GB * 1024**3
        quota_human = f"{int(DISK_QUOTA_GB)} GB" if DISK_QUOTA_GB > 0 else "N/A"
        usage_percent = (used_space_bytes / quota_bytes * 100) if quota_bytes > 0 else 0
        all_items = os.listdir(abs_path)
        visible_items = [item for item in all_items if not item.startswith('.')]
        items = [{'name': item, 'is_dir': os.path.isdir(os.path.join(abs_path, item))} for item in visible_items]
        items.sort(key=lambda x: (not x['is_dir'], x['name'].lower()))
        return render_template('files.html', items=items, current_path=req_path,
                               used_space_human=used_space_human, quota_human=quota_human,
                               usage_percent=usage_percent, quota_gb=DISK_QUOTA_GB)
    else: return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path))
@app.route('/upload', methods=['POST'])
@login_required
def upload_file():
    path = request.form.get('path', ''); dest_path = os.path.join(app.config['DRIVE_ROOT'], path)
    if not os.path.abspath(dest_path).startswith(app.config['DRIVE_ROOT']): return "非法上传路径", 400
    if 'file' not in request.files or request.files['file'].filename == '': return "没有选择文件", 400
    file = request.files['file']
    if DISK_QUOTA_GB > 0:
        file.seek(0, os.SEEK_END); incoming_file_size = file.tell(); file.seek(0)
        current_dir_size = get_directory_size(app.config['DRIVE_ROOT'])
        if current_dir_size + incoming_file_size > DISK_QUOTA_GB * 1024**3:
            return f"上传失败：网盘空间不足。总配额: {DISK_QUOTA_GB} GB", 413
    if file:
        filename = secure_filename(file.filename); file.save(os.path.join(dest_path, filename))
    return "上传成功", 200

# --- API 路由 (供JavaScript调用) ---
@app.route('/api/create_folder', methods=['POST'])
@login_required
def api_create_folder():
    data = request.get_json()
    if not data or 'path' not in data or 'folder_name' not in data: return jsonify({'success': False, 'message': '无效的请求'}), 400
    path, folder_name = data['path'], data['folder_name']
    if not folder_name: return jsonify({'success': False, 'message': '文件夹名称不能为空'}), 400
    new_folder_path = os.path.join(app.config['DRIVE_ROOT'], path, folder_name)
    if not os.path.abspath(new_folder_path).startswith(app.config['DRIVE_ROOT']):
        return jsonify({'success': False, 'message': '非法路径'}), 400
    if os.path.exists(new_folder_path):
        return jsonify({'success': False, 'message': f"文件夹或文件 '{folder_name}' 已存在。"}), 409
    try:
        os.makedirs(new_folder_path)
        return jsonify({'success': True, 'message': f"文件夹 '{folder_name}' 创建成功！"})
    except Exception as e:
        return jsonify({'success': False, 'message': f"创建时发生错误: {e}"}), 500
@app.route('/api/share', methods=['POST'])
@login_required
def api_create_share_link():
    data = request.get_json();
    if not data or 'path' not in data: return jsonify({'error': '无效的请求'}), 400
    req_path = data['path']
    abs_path = os.path.join(app.config['DRIVE_ROOT'], req_path)
    if not os.path.exists(abs_path) or os.path.isdir(abs_path):
        return jsonify({'error': '只能分享已存在的文件'}), 404
    with open(SHARES_FILE, 'r+') as f:
        shares = json.load(f); token = uuid.uuid4().hex; shares[token] = req_path
        f.seek(0); f.truncate(); json.dump(shares, f, indent=4)
    share_link = url_for('public_download', token=token, _external=True)
    return jsonify({'share_url': share_link})
@app.route('/api/delete', methods=['POST'])
@login_required
def api_delete_item():
    data = request.get_json()
    if not data or 'path' not in data:
        return jsonify({'success': False, 'message': '无效的请求'}), 400
    req_path = data['path']
    base_dir = app.config['DRIVE_ROOT']
    abs_path = os.path.join(base_dir, req_path)
    if not os.path.abspath(abs_path).startswith(base_dir) or abs_path == base_dir:
        return jsonify({'success': False, 'message': '非法操作：禁止删除根目录或越权删除'}), 403
    try:
        if os.path.isfile(abs_path):
            os.remove(abs_path)
            return jsonify({'success': True, 'message': '文件已删除'})
        elif os.path.isdir(abs_path):
            shutil.rmtree(abs_path)
            return jsonify({'success': True, 'message': '文件夹已删除'})
        else:
            return jsonify({'success': False, 'message': '目标不存在'}), 404
    except Exception as e:
        return jsonify({'success': False, 'message': f'删除时发生错误: {e}'}), 500

# --- 公开访问路由 ---
@app.route('/public/<token>')
def public_download(token):
    try:
        with open(SHARES_FILE, 'r') as f: shares = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError): return "分享服务不可用", 500
    req_path = shares.get(token)
    if not req_path: return "分享链接无效或已过期", 404
    abs_path = os.path.join(app.config['DRIVE_ROOT'], req_path)
    if not os.path.exists(abs_path): return "分享的文件不存在", 404
    return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path))
EOF

# 创建 wsgi.py 和 templates
cat << EOF > "${PROJECT_DIR}/wsgi.py"
from app import app
if __name__ == "__main__": app.run()
EOF
mkdir -p "${PROJECT_DIR}/templates"
cat << 'EOF' > "${PROJECT_DIR}/templates/login.html"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@1/css/pico.min.css"><title>登录</title></head><body><main class="container"><article><h1 style="text-align: center;">登录到你的网盘</h1><form method="post"><input type="text" name="username" placeholder="用户名" required><input type="password" name="password" placeholder="密码" required><button type="submit">登录</button></form>{% with messages = get_flashed_messages() %}{% if messages %}{% for message in messages %}<p><small style="color: var(--pico-color-red-500);">{{ message }}</small></p>{% endfor %}{% endif %}{% endwith %}</article></main></body></html>
EOF
cat << 'EOF' > "${PROJECT_DIR}/templates/files.html"
<!doctype html><html lang="zh-CN" data-theme="light"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@1/css/pico.min.css"><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css"><title>我的网盘 - {{ current_user.username }}</title><style>:root{--pico-card-padding:1rem;--pico-block-spacing-vertical:1rem}body{background-color:var(--pico-secondary-background)}.action-icon{cursor:pointer;font-size:1rem;margin-left:1rem;transition:transform .2s ease-in-out}.action-icon:hover{transform:scale(1.2)}.share-icon{color:var(--pico-primary-hover)}.delete-icon{color:var(--pico-color-red-500)}.file-list li{display:flex;align-items:center;margin-bottom:.5rem;padding:.25rem 0;border-bottom:1px solid var(--pico-card-border-color)}.file-list li:last-child{border-bottom:none}.file-list a{flex-grow:1;text-decoration:none}.file-list a:hover{text-decoration:underline}#create-folder-form input,#upload-form input{margin-bottom:.5rem}.header-card{text-align:center;padding:1.5rem}.capacity-text{margin-top:0;font-size:.9rem;color:var(--pico-secondary-foreground)}.capacity-bar{height:10px;margin-bottom:0}nav{padding:0}main>.nav-actions{margin-top:1rem;display:flex;justify-content:center;gap:1rem}</style></head><body>
<header class="container"><nav><ul><li><a href="{{url_for('files_view')}}" style="font-weight:bold;font-size:1.2rem;text-decoration:none">我的云盘</a></li></ul><ul><li><span>欢迎, {{current_user.username}}</span><a href="{{url_for('logout')}}" role="button" class="secondary outline" style="margin-left:1rem;width:auto">登出</a></li></ul></nav></header>
<main class="container">
<div class="grid"><article class="header-card"><i class="fa-solid fa-user-circle" style="font-size:3rem;color:var(--pico-primary)"></i><hgroup><h4 style="margin-bottom:0">{{current_user.username}}</h4><p>管理员</p></hgroup></article><article class="header-card">{% if quota_gb > 0 %}<hgroup><h5 style="margin-bottom:0.5rem">已用容量</h5><p class="capacity-text">{{used_space_human}} / {{quota_human}}</p></hgroup><progress class="capacity-bar" value="{{usage_percent}}" max="100" title="{{usage_percent|round(2)}}%"></progress>{% else %}<hgroup><h5>磁盘空间</h5><p>未设置配额</p></hgroup>{% endif %}</article></div>
<article><nav><ul><li><strong>当前路径: /{{current_path}}</strong></li></ul><ul><li><a href="#" id="create-folder-link" style="text-decoration:none" title="创建新文件夹"><i class="fa-solid fa-folder-plus"></i> 创建文件夹</a></li></ul></nav><hr style="margin-top:0">
<ul class="file-list">{% if current_path %}<li><a href="{{ url_for('files_view', req_path=current_path.rsplit('/', 1)[0] if '/' in current_path else '') }}">.. (返回上级)</a></li>{% endif %}{% for item in items %}<li>{% if item.is_dir %}<span>📁 <a href="{{ url_for('files_view', req_path=current_path + '/' + item.name if current_path else item.name) }}"><strong>{{ item.name }}</strong></a></span><i class="fa-solid fa-trash-can action-icon delete-icon" onclick="deleteItem('{{ current_path + '/' + item.name if current_path else item.name }}', '{{ item.name }}')" title="删除文件夹"></i>{% else %}<span>📄 <a href="{{ url_for('files_view', req_path=current_path + '/' + item.name if current_path else item.name) }}">{{ item.name }}</a></span><i class="fa-solid fa-share-nodes action-icon share-icon" onclick="getAndCopyShareLink('{{ current_path + '/' + item.name if current_path else item.name }}')" title="创建并复制分享链接"></i><i class="fa-solid fa-trash-can action-icon delete-icon" onclick="deleteItem('{{ current_path + '/' + item.name if current_path else item.name }}', '{{ item.name }}')" title="删除文件"></i>{% endif %}</li>{% else %}<li><small>当前目录为空</small></li>{% endfor %}</ul>
</article>
<div class="nav-actions"><button id="upload-btn">上传文件</button></div>

<dialog id="create-folder-modal"><article><header><a href="#close" aria-label="Close" class="close"></a><strong>创建新文件夹</strong></header><form id="create-folder-form"><input type="hidden" name="path" value="{{current_path}}"><input type="text" name="folder_name" placeholder="新文件夹名称" required><footer style="display:flex;justify-content:flex-end"><button type="submit" class="primary">确认创建</button></footer></form></article></dialog>
<dialog id="upload-modal"><article><header><a href="#close" aria-label="Close" class="close"></a><strong>上传文件到当前目录</strong></header><form id="upload-form"><input type="hidden" name="path" value="{{current_path}}"><input type="file" name="file" required><progress id="upload-progress" value="0" max="100" style="display:none"></progress><footer><button type="submit" class="primary">确认上传</button></footer></form></article></dialog>
</main>
<script>
// Modal handling
const createFolderModal=document.getElementById('create-folder-modal'),uploadModal=document.getElementById('upload-modal');
document.getElementById('create-folder-link').addEventListener('click',e=>{e.preventDefault();createFolderModal.showModal()});
document.getElementById('upload-btn').addEventListener('click',e=>{uploadModal.showModal()});
document.querySelectorAll('dialog .close').forEach(btn=>btn.addEventListener('click',e=>{e.preventDefault();btn.closest('dialog').close()}));

// Create Folder via API
const createFolderForm=document.getElementById('create-folder-form');createFolderForm.addEventListener('submit',function(e){e.preventDefault();const formData=new FormData(createFolderForm);fetch("{{url_for('api_create_folder')}}",{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:formData.get('path'),folder_name:formData.get('folder_name')})}).then(res=>res.json()).then(data=>{alert(data.message);if(data.success)window.location.reload()}).catch(err=>{alert('发生错误: '+err);console.error(err)})});

// Upload with Progress
const uploadForm=document.getElementById('upload-form');const progressBar=document.getElementById('upload-progress');uploadForm.addEventListener('submit',function(e){e.preventDefault();progressBar.style.display='block';progressBar.value=0;const formData=new FormData(uploadForm);const xhr=new XMLHttpRequest;xhr.upload.addEventListener('progress',function(e){if(e.lengthComputable){progressBar.value=Math.round(e.loaded/e.total*100)}});xhr.addEventListener('load',function(){progressBar.value=100;if(xhr.status>=200&&xhr.status<300){alert('上传成功！');window.location.reload()}else{alert('上传失败：'+xhr.responseText||'服务器错误')}});xhr.addEventListener('error',function(){alert('上传失败！'),progressBar.style.display='none'});xhr.open('POST',"{{url_for('upload_file')}}");xhr.send(formData)});

// Share link
function getAndCopyShareLink(filePath){fetch("{{url_for('api_create_share_link')}}",{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:filePath})}).then(response=>{if(!response.ok)throw new Error('服务器响应错误');return response.json()}).then(data=>{if(data.share_url){if(navigator.clipboard&&window.isSecureContext){navigator.clipboard.writeText(data.share_url).then(()=>{alert('分享链接已复制到剪贴板！\n'+data.share_url)}).catch(err=>{prompt('自动复制失败，请手动复制链接:',data.share_url)})}else{prompt('请手动复制以下分享链接 (当前为HTTP非安全连接):',data.share_url)}}else{throw new Error(data.error||'无法获取分享链接')}}).catch(error=>{console.error('获取分享链接失败:',error);alert('创建分享链接失败: '+error.message)})}

// Delete item
function deleteItem(itemPath,itemName){if(confirm(`你确定要永久删除 '${itemName}' 吗？这个操作无法撤销！`)){fetch("{{url_for('api_delete_item')}}",{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:itemPath})}).then(response=>response.json()).then(data=>{alert(data.message);if(data.success){window.location.reload()}}).catch(error=>{console.error('删除时发生错误:',error);alert('删除失败: '+error.message)})}}
</script></body></html>
EOF

chown -R "$NEW_USERNAME:$NEW_USERNAME" "$PROJECT_DIR"
echo -e "${GREEN}项目文件创建完成！${NC}"

# --- 5. 配置Gunicorn服务 ---
echo -e "\n${YELLOW}>>> 步骤 4/9: 配置Gunicorn后台服务...${NC}"
cat << EOF > /etc/systemd/system/my_cloud_drive.service
[Unit]
Description=Gunicorn instance to serve my_cloud_drive
After=network.target
[Service]
User=${NEW_USERNAME}
Group=www-data
WorkingDirectory=${PROJECT_DIR}
Environment="PATH=${PROJECT_DIR}/venv/bin"
Environment="SECRET_KEY=${APP_SECRET_KEY}"
Environment="DRIVE_ROOT=${DRIVE_ROOT_DIR}"
Environment="DISK_QUOTA_GB=${DISK_QUOTA_GB}"
Environment="APP_USERNAME=${APP_USERNAME}"
Environment="APP_PASSWORD=${APP_PASSWORD}"
ExecStart=${PROJECT_DIR}/venv/bin/gunicorn --workers 3 --timeout 1800 --bind unix:${PROJECT_DIR}/my_cloud_drive.sock -m 007 wsgi:app
[Install]
WantedBy=multi-user.target
EOF
echo -e "${GREEN}Gunicorn服务配置完成！${NC}"

# --- 6. 配置Nginx服务 ---
echo -e "\n${YELLOW}>>> 步骤 5/9: 配置Nginx反向代理...${NC}"
cat << EOF > /etc/nginx/sites-available/my_cloud_drive
server {
    listen 80;
    server_name ${DOMAIN_OR_IP};
    client_max_body_size 1024M;
    location / {
        include proxy_params;
        proxy_pass http://unix:${PROJECT_DIR}/my_cloud_drive.sock;
    }
}
EOF
ln -s /etc/nginx/sites-available/my_cloud_drive /etc/nginx/sites-enabled/ > /dev/null 2>&1
rm -f /etc/nginx/sites-enabled/default
echo -e "${GREEN}Nginx配置完成！${NC}"

# --- 7. 配置防火墙 ---
echo -e "\n${YELLOW}>>> 步骤 6/9: 配置iptables防火墙...${NC}"
iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT > /dev/null 2>&1
iptables -I INPUT 2 -p tcp --dport 443 -j ACCEPT > /dev/null 2>&1
iptables-save > /etc/iptables/rules.v4
echo -e "${GREEN}防火墙已放行80和443端口！${NC}"

# --- 8. 开启BBR并启动所有服务 ---
echo -e "\n${YELLOW}>>> 步骤 7/9: 开启BBR并启动服务...${NC}"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    cat << EOF >> /etc/sysctl.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
fi
sysctl -p > /dev/null 2>&1
systemctl daemon-reload
systemctl start my_cloud_drive
systemctl enable my_cloud_drive > /dev/null 2>&1
nginx -t
if [ $? -eq 0 ]; then
    systemctl restart nginx
else
    echo -e "${RED}Nginx配置测试失败，请检查。${NC}"; exit 1;
fi
echo -e "${GREEN}HTTP服务已启动！${NC}"

# --- 9. 自动配置HTTPS ---
echo -e "\n${YELLOW}>>> 步骤 8/9: 尝试自动配置HTTPS...${NC}"
FINAL_URL="http://${DOMAIN_OR_IP}"
if [[ ! "$DOMAIN_OR_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo -e "${YELLOW}检测到输入为域名，开始申请SSL证书...${NC}"
    certbot --nginx --non-interactive --agree-tos --redirect --email "${LETSENCRYPT_EMAIL}" -d "${DOMAIN_OR_IP}"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}HTTPS配置成功！${NC}"
        FINAL_URL="https://${DOMAIN_OR_IP}"
    else
        echo -e "${RED}SSL证书申请失败。请检查你的域名是否正确解析到了该服务器IP。${NC}"
        echo -e "${YELLOW}网站仍然可以通过HTTP访问。${NC}"
    fi
else
    echo -e "${YELLOW}检测到输入为IP地址，跳过HTTPS配置。${NC}"
fi

# --- 部署完成 ---
echo -e "\n${YELLOW}>>> 步骤 9/9: 部署完成！${NC}"
echo
echo -e "${GREEN}===================================================================${NC}"
echo -e "${GREEN}  恭喜！您的个人网盘已成功部署！                           ${NC}"
echo -e "${GREEN}-------------------------------------------------------------------${NC}"
echo -e "  访问地址:   ${YELLOW}${FINAL_URL}${NC}"
echo -e "  网盘总容量: ${YELLOW}${DISK_QUOTA_GB} GB${NC}"
echo -e "  登录用户:   ${YELLOW}${APP_USERNAME}${NC}"
echo -e "  登录密码:   (您刚才设置的密码)"
echo -e "  系统管理用户: ${YELLOW}${NEW_USERNAME}${NC}"
echo -e "  系统管理密码: (您刚才设置的密码)"
echo -e "${GREEN}===================================================================${NC}"

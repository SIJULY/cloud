#!/bin/bash

# ==============================================================================
#           个人网盘项目 V5.0 - 专业版 UI + Caddy (修复版)
#
# 核心特性:
# 1. [UI重构] 基于 Bootstrap 5 的专业后台布局 (侧边栏+顶部导航)。
# 2. [新功能] 右键菜单、多选操作、列表/大图视图切换、重命名、移动文件。
# 3. [修复] 修复了 gnupg 缺失导致的 Caddy 安装失败问题。
# 4. [修复] 修复了 Python 虚拟环境创建时的权限错误。
# 5. [继承] 保留了 V4.0 的 Caddy 自动 HTTPS 和断点续传上传功能。
# ==============================================================================

# --- 检查 Root ---
if [ "$(id -u)" -ne 0 ]; then echo -e "\033[31m错误：此脚本必须以 root 用户身份运行。\033[0m"; exit 1; fi

# --- 1. 信息收集 ---
clear
echo -e "\033[32m=====================================================\033[0m"
echo -e "\033[32m    欢迎使用个人网盘 V5.0 专业版一键部署脚本    \033[0m"
echo -e "\033[32m=====================================================\033[0m"

read -p "请输入日常管理用户名 (例如: auser): " NEW_USERNAME
while true; do read -sp "请输入该用户的登录密码 (输入时不可见): " NEW_PASSWORD; echo; read -sp "请再次输入密码进行确认: " NEW_PASSWORD_CONFIRM; echo; if [ "$NEW_PASSWORD" = "$NEW_PASSWORD_CONFIRM" ]; then break; else echo -e "\033[31m两次输入的密码不匹配，请重试。\033[0m"; fi; done

read -p "请输入您的域名 (例如: drive.example.com，会自动开启HTTPS): " DOMAIN_OR_IP

read -p "请为网盘应用设置一个登录用户名 (例如: admin): " APP_USERNAME
while true; do read -sp "请为网盘应用设置一个登录密码 (输入时不可见): " APP_PASSWORD; echo; read -sp "请再次输入密码进行确认: " APP_PASSWORD_CONFIRM; echo; if [ "$APP_PASSWORD" = "$APP_PASSWORD_CONFIRM" ]; then break; else echo -e "\033[31m两次输入的密码不匹配，请重试。\033[0m"; fi; done

echo -e "\n\033[33m>>> 信息收集完毕，开始部署 V5.0 专业版...\033[0m"
sleep 2

# --- 2. 系统初始化与依赖安装 (修复点: 添加 gnupg) ---
echo -e "\n\033[33m>>> 步骤 1/7: 更新系统并安装依赖...\033[0m"
apt-get update -y > /dev/null 2>&1
# [修复] 添加 gnupg 以支持 Caddy 密钥导入
apt-get install -y python3-pip python3-dev python3-venv debian-keyring debian-archive-keyring apt-transport-https curl gnupg > /dev/null 2>&1

# 创建用户
if ! id "$NEW_USERNAME" &>/dev/null; then
    adduser --disabled-password --gecos "" "$NEW_USERNAME" > /dev/null 2>&1
    echo "$NEW_USERNAME:$NEW_PASSWORD" | chpasswd
    usermod -aG sudo "$NEW_USERNAME"
fi

# --- 3. 安装 Caddy (修复点: 确保密钥添加成功) ---
echo -e "\n\033[33m>>> 步骤 2/7: 安装 Caddy Web 服务器...\033[0m"
# 卸载 Nginx 防止冲突
systemctl stop nginx > /dev/null 2>&1; systemctl disable nginx > /dev/null 2>&1; apt-get remove -y nginx nginx-common > /dev/null 2>&1

# 添加 Caddy 源
rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
apt-get update > /dev/null 2>&1
apt-get install -y caddy > /dev/null 2>&1

# --- 4. 部署后端项目 (修复点: 权限顺序) ---
echo -e "\n\033[33m>>> 步骤 3/7: 部署 Python 后端环境...\033[0m"
PROJECT_DIR="/var/www/my_cloud_drive"
DRIVE_ROOT_DIR="/home/${NEW_USERNAME}/my_files"
mkdir -p "$PROJECT_DIR" "$DRIVE_ROOT_DIR"
# [修复] 先设置项目目录权限，再创建 venv
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$PROJECT_DIR"
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$DRIVE_ROOT_DIR"

# 以新用户身份创建 venv
if [ ! -d "${PROJECT_DIR}/venv" ]; then
    su - "$NEW_USERNAME" -c "cd $PROJECT_DIR && python3 -m venv venv"
fi
# 安装依赖
su - "$NEW_USERNAME" -c "source ${PROJECT_DIR}/venv/bin/activate && pip install Flask Gunicorn" > /dev/null 2>&1

APP_SECRET_KEY=$(openssl rand -hex 32)

# --- 写入 V5.0 app.py (新增重命名和移动 API) ---
echo -e "\n\033[33m>>> 步骤 4/7: 写入后端代码 (app.py)...\033[0m"
cat << EOF > "${PROJECT_DIR}/app.py"
import os, json, uuid, shutil, time
from functools import wraps
from flask import Flask, render_template, request, send_from_directory, redirect, url_for, flash, jsonify, session
from werkzeug.utils import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash

SECRET_KEY = os.environ.get('SECRET_KEY', '${APP_SECRET_KEY}')
DRIVE_ROOT = os.environ.get('DRIVE_ROOT', '${DRIVE_ROOT_DIR}')
APP_USERNAME = os.environ.get('APP_USERNAME', 'admin')
APP_PASSWORD_HASH = generate_password_hash(os.environ.get('APP_PASSWORD', 'password'))
SHARES_FILE = os.path.join(DRIVE_ROOT, '.shares.json')
TEMP_DIR = os.path.join(DRIVE_ROOT, '.temp_uploads')

app = Flask(__name__)
app.config['SECRET_KEY'] = SECRET_KEY
app.config['DRIVE_ROOT'] = os.path.abspath(DRIVE_ROOT)
app.config['MAX_CONTENT_LENGTH'] = None 

os.makedirs(app.config['DRIVE_ROOT'], exist_ok=True)
os.makedirs(TEMP_DIR, exist_ok=True)
if not os.path.exists(SHARES_FILE):
    with open(SHARES_FILE, 'w') as f: json.dump({}, f)

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'user' not in session: return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

def format_bytes(size):
    power = 2**10; n = 0; power_labels = {0 : '', 1: 'K', 2: 'M', 3: 'G', 4: 'T'}
    while size > power: size /= power; n += 1
    return f"{size:.2f} {power_labels[n]}B"

def get_disk_usage():
    total, used, free = shutil.disk_usage(app.config['DRIVE_ROOT'])
    return format_bytes(used), format_bytes(total), (used / total * 100)

def atomic_write_json(filepath, data):
    temp_path = filepath + '.tmp'
    with open(temp_path, 'w') as f: json.dump(data, f, indent=4)
    os.replace(temp_path, filepath)

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if request.form['username'] == APP_USERNAME and check_password_hash(APP_PASSWORD_HASH, request.form['password']):
            session['user'] = APP_USERNAME
            return redirect(url_for('files_view'))
        flash('用户名或密码错误')
    return render_template('login.html')

@app.route('/logout')
def logout(): session.pop('user', None); return redirect(url_for('login'))

@app.route('/', defaults={'req_path': ''})
@app.route('/<path:req_path>')
@login_required
def files_view(req_path):
    base_dir = app.config['DRIVE_ROOT']
    abs_path = os.path.join(base_dir, req_path)
    if not os.path.abspath(abs_path).startswith(base_dir): return "非法路径", 400
    if abs_path.startswith(TEMP_DIR): return "拒绝访问", 403

    if os.path.exists(abs_path) and os.path.isdir(abs_path):
        used_h, total_h, percent = get_disk_usage()
        try: items = sorted(os.listdir(abs_path))
        except: return "无法读取目录", 500
        file_list = []
        for item in items:
            if item.startswith('.'): continue
            full = os.path.join(abs_path, item)
            is_dir = os.path.isdir(full)
            ftype = 'dir' if is_dir else 'file'
            if not is_dir:
                l = item.lower()
                if l.endswith(('.png','.jpg','.jpeg','.gif','.webp')): ftype = 'image'
                elif l.endswith(('.mp4','.webm','.mov')): ftype = 'video'
                elif l.endswith(('.pdf')): ftype = 'pdf'
                elif l.endswith(('.txt','.md','.py','.js','.css','.html')): ftype = 'text'
            
            mtime = time.strftime('%Y-%m-%d %H:%M', time.localtime(os.path.getmtime(full)))
            file_list.append({'name': item, 'is_dir': is_dir, 'type': ftype, 'size': '-' if is_dir else format_bytes(os.path.getsize(full)), 'mtime': mtime})
        
        file_list.sort(key=lambda x: (not x['is_dir'], x['name'].lower()))
        return render_template('files.html', items=file_list, current_path=req_path, used=used_h, total=total_h, percent=percent, username=session['user'])
    elif os.path.exists(abs_path):
        return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path))
    return "文件不存在", 404

# --- Upload API (V4.0 Chunked Logic) ---
@app.route('/api/upload_check', methods=['POST'])
@login_required
def upload_check():
    data = request.get_json()
    identifier = secure_filename(f"{data['path']}_{data['filename']}_{data['totalSize']}")
    temp_file = os.path.join(TEMP_DIR, identifier)
    return jsonify({'uploaded': os.path.getsize(temp_file) if os.path.exists(temp_file) else 0})

@app.route('/api/upload_chunk', methods=['POST'])
@login_required
def upload_chunk():
    file = request.files['file']; filename = request.form['filename']; path = request.form['path']; total_size = int(request.form['totalSize'])
    identifier = secure_filename(f"{path}_{filename}_{total_size}"); temp_file = os.path.join(TEMP_DIR, identifier)
    with open(temp_file, 'ab') as f: f.write(file.read())
    if os.path.getsize(temp_file) >= total_size:
        dest_path = os.path.join(app.config['DRIVE_ROOT'], path, secure_filename(filename))
        base, ext = os.path.splitext(dest_path); counter = 1
        while os.path.exists(dest_path): dest_path = f"{base}_{counter}{ext}"; counter += 1
        shutil.move(temp_file, dest_path); return jsonify({'status': 'done'})
    return jsonify({'status': 'chunk_saved'})

# --- Operations API (Enhanced for V5.0) ---
@app.route('/api/operate', methods=['POST'])
@login_required
def api_operate():
    data = request.get_json(); action = data.get('action'); path = data.get('path'); base = app.config['DRIVE_ROOT']
    
    # Handle multi-selection for delete/move
    paths = data.get('paths', [path]) if path else data.get('paths', [])

    try:
        if action == 'mkdir':
            target = os.path.join(base, path, data.get('name'))
            if not os.path.abspath(target).startswith(base): return jsonify({'ok': False, 'msg': '非法路径'}), 403
            os.makedirs(target, exist_ok=False)
            
        elif action == 'delete':
            for p in paths:
                target = os.path.join(base, p)
                if not os.path.abspath(target).startswith(base) or target == base: continue
                shutil.rmtree(target) if os.path.isdir(target) else os.remove(target)

        elif action == 'rename':
            target = os.path.join(base, path)
            new_name = secure_filename(data.get('new_name'))
            new_target = os.path.join(os.path.dirname(target), new_name)
            if not os.path.abspath(target).startswith(base) or not os.path.abspath(new_target).startswith(base): return jsonify({'ok': False, 'msg': '非法路径'}), 403
            if os.path.exists(new_target): return jsonify({'ok': False, 'msg': '新文件名已存在'}), 409
            os.rename(target, new_target)

        elif action == 'move':
            dest_folder = data.get('dest')
            dest_base = os.path.join(base, dest_folder)
            if not os.path.abspath(dest_base).startswith(base): return jsonify({'ok': False, 'msg': '非法目标路径'}), 403
            for p in paths:
                src = os.path.join(base, p)
                if not os.path.abspath(src).startswith(base) or src == base: continue
                shutil.move(src, dest_base)

        elif action == 'share':
            target = os.path.join(base, path)
            if os.path.isdir(target): return jsonify({'ok': False, 'msg': '仅支持分享文件'})
            with open(SHARES_FILE, 'r') as f: shares = json.load(f)
            token = uuid.uuid4().hex; shares[token] = path; atomic_write_json(SHARES_FILE, shares)
            return jsonify({'ok': True, 'link': url_for('public_download', token=token, _external=True)})
            
        return jsonify({'ok': True})
    except Exception as e: return jsonify({'ok': False, 'msg': str(e)})

@app.route('/preview/<path:req_path>')
@login_required
def preview_file(req_path):
    abs_path = os.path.join(app.config['DRIVE_ROOT'], req_path)
    return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path))

@app.route('/s/<token>')
def public_download(token):
    try:
        with open(SHARES_FILE, 'r') as f: shares = json.load(f)
        req_path = shares.get(token)
        if not req_path: return "链接已失效", 404
        abs_path = os.path.join(app.config['DRIVE_ROOT'], req_path)
        return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path), as_attachment=True)
    except: return "服务器错误", 500
EOF

# --- 写入 wsgi.py ---
echo "from app import app" > "${PROJECT_DIR}/wsgi.py"
echo 'if __name__ == "__main__": app.run()' >> "${PROJECT_DIR}/wsgi.py"

# --- 写入专业版前端模板 (Bootstrap 5) ---
echo -e "\n\033[33m>>> 步骤 5/7: 写入专业版前端模板...\033[0m"
mkdir -p "${PROJECT_DIR}/templates"

# 1. Login 模板 (Bootstrap 版)
cat << 'EOF' > "${PROJECT_DIR}/templates/login.html"
<!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>登录云盘</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><style>body{display:flex;align-items:center;padding-top:40px;padding-bottom:40px;background-color:#f5f5f5;height:100vh}.form-signin{width:100%;max-width:330px;padding:15px;margin:auto}.form-signin .form-floating:focus-within{z-index:2}.form-signin input[type="text"]{margin-bottom:-1px;border-bottom-right-radius:0;border-bottom-left-radius:0}.form-signin input[type="password"]{margin-bottom:10px;border-top-left-radius:0;border-top-right-radius:0}</style></head><body class="text-center"><main class="form-signin"><form method="post"><h1 class="h3 mb-3 fw-normal">请登录</h1><div class="form-floating"><input type="text" class="form-control" id="floatingInput" name="username" placeholder="用户名" required><label for="floatingInput">用户名</label></div><div class="form-floating"><input type="password" class="form-control" id="floatingPassword" name="password" placeholder="密码" required><label for="floatingPassword">密码</label></div><button class="w-100 btn btn-lg btn-primary" type="submit">登录</button>{% with m=get_flashed_messages() %}{% if m %}<div class="alert alert-danger mt-3">{{m[0]}}</div>{% endif %}{% endwith %}</form></main></body></html>
EOF

# 2. Files 主界面模板 (V5.0 专业版核心)
# 包含：侧边栏布局、两种视图、右键菜单、多选、上传面板等
cat << 'EOF' > "${PROJECT_DIR}/templates/files.html"
<!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>我的云盘 V5.0 专业版</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.5/font/bootstrap-icons.css"><style>
:root{--sidebar-width:240px}body{min-height:100vh;background-color:#f8f9fa}.sidebar{width:var(--sidebar-width);position:fixed;top:56px;bottom:0;left:0;z-index:100;padding:0;box-shadow:inset -1px 0 0 rgba(0,0,0,.1)}.main-content{margin-left:var(--sidebar-width);padding:20px}.navbar-brand{padding-top:.75rem;padding-bottom:.75rem;font-size:1rem;background-color:rgba(0,0,0,.25);box-shadow:inset -1px 0 0 rgba(0,0,0,.25)}.file-icon{font-size:1.5rem;margin-right:10px}.file-item{cursor:pointer;user-select:none}.file-item.selected{background-color:#e9ecef}.context-menu{display:none;position:absolute;z-index:1000;background:#fff;border:1px solid #ccc;box-shadow:2px 2px 5px rgba(0,0,0,.2)}.context-menu .dropdown-item{cursor:pointer}#upload-panel{position:fixed;bottom:20px;right:20px;width:300px;z-index:1050;display:none}.view-grid .file-item{text-align:center;padding:15px}.view-grid .file-icon{font-size:3rem;display:block;margin:0 auto 10px}.view-grid .file-meta{display:none}.drag-over{border:2px dashed #0d6efd!important;background-color:#f1f8ff}.text-truncate{max-width:100%}
</style></head><body>

<header class="navbar navbar-dark sticky-top bg-dark flex-md-nowrap p-0 shadow"><a class="navbar-brand col-md-3 col-lg-2 me-0 px-3 fs-6" href="#">☁️ 私有云盘 V5.0</a><div class="navbar-nav"><div class="nav-item text-nowrap"><a class="nav-link px-3" href="{{url_for('logout')}}">退出 [{{username}}]</a></div></div></header>

<div class="container-fluid"><div class="row">
    <nav id="sidebarMenu" class="col-md-3 col-lg-2 d-md-block bg-light sidebar collapse"><div class="position-sticky pt-3"><ul class="nav flex-column"><li class="nav-item"><a class="nav-link active" aria-current="page" href="{{url_for('files_view', req_path='')}}"><i class="bi bi-hdd-network me-2"></i> 全部文件</a></li><li class="nav-item"><a class="nav-link disabled" href="#"><i class="bi bi-share me-2"></i> 我的分享 (开发中)</a></li></ul><div class="mt-4 px-3"><h6>存储空间</h6><div class="progress" style="height: 8px;"><div class="progress-bar" role="progressbar" style="width: {{percent}}%;" aria-valuenow="{{percent}}" aria-valuemin="0" aria-valuemax="100"></div></div><small class="text-muted">{{used}} / {{total}}</small></div></div></nav>

    <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4 main-content" id="main-drop-zone">
        <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
            <nav aria-label="breadcrumb"><ol class="breadcrumb mb-0"><li class="breadcrumb-item"><a href="{{url_for('files_view', req_path='')}}">根目录</a></li>{% if current_path %}{% for part in current_path.split('/') %}<li class="breadcrumb-item active">{{part}}</li>{% endfor %}{% endif %}</ol></nav>
            <div class="btn-toolbar mb-2 mb-md-0">
                <div class="btn-group me-2">
                    <button type="button" class="btn btn-sm btn-outline-primary" onclick="document.getElementById('file-input').click()"><i class="bi bi-upload"></i> 上传</button>
                    <button type="button" class="btn btn-sm btn-outline-secondary" data-bs-toggle="modal" data-bs-target="#newFolderModal"><i class="bi bi-folder-plus"></i> 新建文件夹</button>
                </div>
                <div class="btn-group">
                    <button type="button" class="btn btn-sm btn-outline-secondary active" id="view-list-btn"><i class="bi bi-list-ul"></i></button>
                    <button type="button" class="btn btn-sm btn-outline-secondary" id="view-grid-btn"><i class="bi bi-grid"></i></button>
                </div>
            </div>
        </div>
        <input type="file" id="file-input" multiple style="display:none">

        <div id="file-container" class="view-list">
            <div class="row fw-bold border-bottom pb-2 mb-2 d-none d-md-flex file-header"><div class="col-6">名称</div><div class="col-2">大小</div><div class="col-4">修改时间</div></div>
            {% if current_path %}<div class="row py-2 border-bottom file-item user-select-none" onclick="location.href='{{url_for('files_view', req_path=current_path.rsplit('/', 1)[0] if '/' in current_path else '')}}'"><div class="col-12"><i class="bi bi-arrow-90deg-up file-icon text-secondary"></i> 返回上一级</div></div>{% endif %}
            {% for item in items %}
            <div class="row py-2 border-bottom file-item user-select-none" data-path="{{(current_path+'/'+item.name) if current_path else item.name}}" data-type="{{item.type}}" data-isdir="{{item.is_dir}}">
                <div class="col-md-6 col-12 d-flex align-items-center text-truncate">
                    {% if item.is_dir %}<i class="bi bi-folder-fill file-icon text-warning"></i>
                    {% elif item.type=='image' %}<i class="bi bi-file-earmark-image file-icon text-primary"></i>
                    {% elif item.type=='video' %}<i class="bi bi-file-earmark-play file-icon text-danger"></i>
                    {% elif item.type=='text' %}<i class="bi bi-file-earmark-text file-icon text-info"></i>
                    {% elif item.type=='pdf' %}<i class="bi bi-file-earmark-pdf file-icon text-danger"></i>
                    {% else %}<i class="bi bi-file-earmark file-icon text-secondary"></i>{% endif %}
                    <span class="text-truncate">{{item.name}}</span>
                </div>
                <div class="col-md-2 d-none d-md-block file-meta">{{item.size}}</div>
                <div class="col-md-4 d-none d-md-block file-meta">{{item.mtime}}</div>
            </div>
            {% else %}<div class="text-center py-5 text-muted"><i class="bi bi-inbox fs-1"></i><p>当前目录为空，拖拽文件到这里上传</p></div>{% endfor %}
        </div>
    </main>
</div></div>

<ul class="dropdown-menu context-menu" id="context-menu">
    <li><a class="dropdown-item" id="cm-open"><i class="bi bi-box-arrow-in-right me-2"></i>打开/预览</a></li>
    <li><a class="dropdown-item" id="cm-download"><i class="bi bi-download me-2"></i>下载</a></li>
    <li><a class="dropdown-item" id="cm-share"><i class="bi bi-share me-2"></i>分享</a></li>
    <li><hr class="dropdown-divider"></li>
    <li><a class="dropdown-item" id="cm-rename"><i class="bi bi-pencil-square me-2"></i>重命名</a></li>
    <li><a class="dropdown-item" id="cm-move" data-bs-toggle="modal" data-bs-target="#moveModal"><i class="bi bi-arrows-move me-2"></i>移动到...</a></li>
    <li><hr class="dropdown-divider"></li>
    <li><a class="dropdown-item text-danger" id="cm-delete"><i class="bi bi-trash me-2"></i>删除</a></li>
</ul>

<div class="card shadow" id="upload-panel"><div class="card-header d-flex justify-content-between align-items-center py-2"><strong>上传队列</strong><button type="button" class="btn-close btn-sm" onclick="$('#upload-panel').hide()"></button></div><div class="card-body p-0 overflow-auto" style="max-height:300px;" id="upload-list"></div></div>

<div class="modal fade" id="newFolderModal" tabindex="-1"><div class="modal-dialog"><div class="modal-content"><div class="modal-header"><h5 class="modal-title">新建文件夹</h5><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div><div class="modal-body"><input type="text" class="form-control" id="newFolderName" placeholder="文件夹名称"></div><div class="modal-footer"><button type="button" class="btn btn-secondary" data-bs-dismiss="modal">取消</button><button type="button" class="btn btn-primary" onclick="createNewFolder()">创建</button></div></div></div></div>
<div class="modal fade" id="moveModal" tabindex="-1"><div class="modal-dialog"><div class="modal-content"><div class="modal-header"><h5 class="modal-title">移动文件</h5><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div><div class="modal-body"><p>将选中的文件移动到 (相对根目录的路径):</p><input type="text" class="form-control" id="moveDestPath" placeholder="例如: photos/2023"></div><div class="modal-footer"><button type="button" class="btn btn-secondary" data-bs-dismiss="modal">取消</button><button type="button" class="btn btn-primary" onclick="moveSelectedFiles()">确定移动</button></div></div></div></div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
<script>
// --- 全局变量 ---
const currentPath = '{{current_path}}';
let selectedPaths = []; const CHUNK_SIZE=5*1024*1024;

// --- 视图切换 ---
$('#view-grid-btn').click(function(){$('#file-container').addClass('view-grid view-list row g-3').removeClass('view-list'); $('.file-header').addClass('d-none'); $(this).addClass('active'); $('#view-list-btn').removeClass('active');});
$('#view-list-btn').click(function(){$('#file-container').removeClass('view-grid row g-3').addClass('view-list'); $('.file-header').removeClass('d-none'); $(this).addClass('active'); $('#view-grid-btn').removeClass('active');});

// --- 文件选择与右键菜单 ---
$('.file-item').on('mousedown', function(e){
    if(e.button === 2) { // 右键
        if(!$(this).hasClass('selected')) {
             $('.file-item').removeClass('selected'); selectedPaths = [];
             $(this).addClass('selected'); selectedPaths.push($(this).data('path'));
        }
        showContextMenu(e.pageX, e.pageY);
        return false;
    }
    // 左键点击选择
    if(e.ctrlKey || e.metaKey) { $(this).toggleClass('selected'); }
    else if(e.shiftKey) { /* 简化处理，暂不支持范围选 */ $(this).addClass('selected'); }
    else { $('.file-item').removeClass('selected'); $(this).addClass('selected'); }
    updateSelection();
});
function updateSelection(){
    selectedPaths = $('.file-item.selected').map(function(){return $(this).data('path')}).get();
    $('#cm-rename, #cm-open, #cm-download, #cm-share').toggleClass('disabled', selectedPaths.length !== 1);
    if(selectedPaths.length === 1){
        const $el = $('.file-item.selected');
        const isDir = $el.data('isdir') == 'True'; const type = $el.data('type'); const path = $el.data('path');
        $('#cm-open').off('click').on('click', ()=> isDir ? location.href=`/${path}` : preview(type, `/preview/${path}`));
        $('#cm-download').attr('href', `/preview/${path}`);
        $('#cm-share').off('click').on('click', ()=> operate('share', {path}));
        $('#cm-rename').off('click').on('click', ()=> renameItem(path));
    }
    $('#cm-delete').off('click').on('click', ()=> deleteSelected());
}
$(document).on('click', function(){ $('#context-menu').hide(); });
function showContextMenu(x, y){
    $('#context-menu').css({top: y, left: x}).show();
    // 根据选中项调整菜单显示
    const $sel = $('.file-item.selected');
    if($sel.length===1 && $sel.data('isdir')=='True') $('#cm-download, #cm-share').hide(); else $('#cm-download, #cm-share').show();
}
$('.file-item').on('dblclick', function(){
    const isDir = $(this).data('isdir') == 'True'; const path = $(this).data('path'); const type = $(this).data('type');
    if(isDir) location.href = `/${path}`; else preview(type, `/preview/${path}`);
});

// --- API 操作 ---
function operate(action, data={}){
    return $.ajax({url:'/api/operate', type:'POST', contentType:'application/json', data:JSON.stringify({action, ...data})})
        .then(res => { if(res.ok){ if(res.link) prompt("分享链接:", res.link); else location.reload(); } else alert(res.msg); });
}
function createNewFolder(){ const name = $('#newFolderName').val(); if(name) operate('mkdir', {path: currentPath, name}); $('#newFolderModal').modal('hide'); }
function deleteSelected(){ if(confirm(`确定删除选中的 ${selectedPaths.length} 个项目吗？`)) operate('delete', {paths: selectedPaths}); }
function renameItem(path){ const newName = prompt("请输入新名称:", path.split('/').pop()); if(newName) operate('rename', {path, new_name: newName}); }
function moveSelectedFiles(){ const dest = $('#moveDestPath').val(); if(dest) operate('move', {paths: selectedPaths, dest}); $('#moveModal').modal('hide'); }
function preview(t,u){ if(t==='image'||t==='video'||t==='pdf') window.open(u); else location.href=u; }

// --- 拖拽上传 (集成 V4.0 逻辑) ---
const $dropZone = $('#main-drop-zone');
$dropZone.on('dragover', e => { e.preventDefault(); $dropZone.addClass('drag-over'); })
         .on('dragleave drop', e => { e.preventDefault(); $dropZone.removeClass('drag-over'); });
$dropZone.on('drop', e => handleFiles(e.originalEvent.dataTransfer.files));
$('#file-input').on('change', e => handleFiles(e.target.files));

async function handleFiles(files){
    if(!files.length) return;
    $('#upload-panel').show();
    for(let file of files) await uploadOne(file);
}
async function uploadOne(file){
    const id = Date.now();
    $('#upload-list').append(`<div class="p-2 border-bottom" id="up-${id}"><div class="d-flex justify-content-between small"><span>${file.name}</span><span class="status">准备中...</span></div><div class="progress mt-1" style="height:4px"><div class="progress-bar bg-primary" style="width:0%"></div></div></div>`);
    const $ui = $(`#up-${id}`); const $bar = $ui.find('.progress-bar'); const $status = $ui.find('.status');
    
    // 断点续传逻辑 (同 V4.0)
    let uploaded=0; try{const res=await $.ajax({url:'/api/upload_check',type:'POST',contentType:'application/json',data:JSON.stringify({filename:file.name,totalSize:file.size,path:currentPath})});uploaded=res.uploaded;}catch(e){}
    if(uploaded>=file.size){ $bar.css('width','100%'); $status.text('秒传成功').addClass('text-success'); return; }
    
    while(uploaded<file.size){
        const chunk=file.slice(uploaded,uploaded+CHUNK_SIZE); const fd=new FormData();
        fd.append('file',chunk);fd.append('filename',file.name);fd.append('path',currentPath);fd.append('totalSize',file.size);
        try{
            $status.text('上传中...'); const res=await $.ajax({url:'/api/upload_chunk',type:'POST',data:fd,processData:false,contentType:false});
            if(res.status==='chunk_saved'||res.status==='done'){ uploaded+=chunk.size; const p=Math.min((uploaded/file.size)*100,100)+'%'; $bar.css('width',p); } else throw 1;
        }catch(e){ $status.text('重试中...').addClass('text-warning'); await new Promise(r=>setTimeout(r,3000)); }
    }
    $status.text('完成').removeClass('text-warning').addClass('text-success'); setTimeout(()=>{$ui.fadeOut();if($('#upload-list').children(':visible').length===0) location.reload()}, 2000);
}
</script></body></html>
EOF
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$PROJECT_DIR"

# --- 6. 配置 Systemd 服务 ---
echo -e "\n\033[33m>>> 步骤 6/7: 配置后台服务...\033[0m"
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
Environment="APP_USERNAME=${APP_USERNAME}"
Environment="APP_PASSWORD=${APP_PASSWORD}"
ExecStart=${PROJECT_DIR}/venv/bin/gunicorn --workers 4 --timeout 300 --bind unix:${PROJECT_DIR}/my_cloud_drive.sock -m 007 wsgi:app
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload > /dev/null
systemctl enable my_cloud_drive > /dev/null
systemctl restart my_cloud_drive

# --- 7. 配置 Caddy (自动HTTPS) ---
echo -e "\n\033[33m>>> 步骤 7/7: 配置 Caddy 反向代理...\033[0m"
cat << EOF > /etc/caddy/Caddyfile
${DOMAIN_OR_IP} {
    request_body {
        max_size 10GB
    }
    encode gzip
    reverse_proxy unix/${PROJECT_DIR}/my_cloud_drive.sock {
        transport http {
            response_header_timeout 300s
        }
    }
}
EOF
systemctl enable caddy > /dev/null
systemctl restart caddy

# --- 结束 ---
echo -e "\n\033[32m=====================================================\033[0m"
echo -e "\033[32m  🎉 V5.0 专业版部署成功！ \033[0m"
echo -e "\033[32m=====================================================\033[0m"
echo -e "  访问地址:   \033[33mhttps://${DOMAIN_OR_IP}\033[0m (请确保域名解析正确)"
echo -e "  登录用户:   \033[33m${APP_USERNAME}\033[0m"
echo -e "  \n  \033[36m新特性提示:\033[0m"
echo -e "  - \033[1m右键点击\033[0m文件可弹出专业菜单（重命名、移动、删除等）。"
echo -e "  - 按住 \033[1mCtrl/Shift\033[0m 可进行多选操作。"
echo -e "  - 点击右上角的按钮可在\033[1m列表视图\033[0m和\033[1m大图视图\033[0m间切换。"
echo -e "\033[32m=====================================================\033[0m"

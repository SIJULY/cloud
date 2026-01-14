#!/bin/bash

# ==============================================================================
#           个人网盘 V6.0 - 旗舰版 (批量下载 + 任务中心 + 卸载功能)
#
# 核心更新:
# 1. [运维] 启动菜单增加“卸载”选项，一键清理环境。
# 2. [交互] 列表增加复选框，顶部增加“下载”按钮。
# 3. [功能] 支持多文件/文件夹批量打包下载 (.zip)。
# 4. [UI] 新增“任务中心”弹窗，统一管理上传/处理进度。
# ==============================================================================

# --- 检查 Root ---
if [ "$(id -u)" -ne 0 ]; then echo -e "\033[31m错误：此脚本必须以 root 用户身份运行。\033[0m"; exit 1; fi

# --- 0. 启动菜单 (安装 vs 卸载) ---
clear
echo -e "\033[32m=====================================================\033[0m"
echo -e "\033[32m       个人网盘 V6.0 旗舰版管理脚本         \033[0m"
echo -e "\033[32m=====================================================\033[0m"
echo -e "请选择操作："
echo -e "  1) 安装 / 更新 (保留数据)"
echo -e "  2) 卸载 (清理服务和配置)"
read -p "请输入数字 [1-2]: " ACTION

# ==================== 卸载逻辑 ====================
if [ "$ACTION" == "2" ]; then
    echo -e "\n\033[33m>>> 正在执行卸载程序...\033[0m"
    
    # 1. 停止并禁用服务
    systemctl stop my_cloud_drive 2>/dev/null
    systemctl disable my_cloud_drive 2>/dev/null
    systemctl stop caddy 2>/dev/null
    
    # 2. 删除服务文件
    rm -f /etc/systemd/system/my_cloud_drive.service
    rm -f /etc/caddy/Caddyfile
    systemctl daemon-reload
    
    # 3. 询问是否删除数据
    read -p "是否删除所有网盘文件数据 (/home/*/my_files)? [y/N]: " DEL_DATA
    if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
        # 尝试查找并删除
        PROJECT_DIR="/var/www/my_cloud_drive"
        # 这一步比较危险，我们只删除项目目录，数据目录建议手动删
        rm -rf "$PROJECT_DIR"
        echo "项目程序已删除。"
        # 再次确认数据
        USER_DATA_DIR=$(ls -d /home/*/my_files 2>/dev/null | head -n 1)
        if [ ! -z "$USER_DATA_DIR" ]; then
            rm -rf "$USER_DATA_DIR"
            echo "用户数据已删除: $USER_DATA_DIR"
        fi
    else
        echo "保留了数据文件和程序目录，仅移除了服务配置。"
    fi
    
    echo -e "\033[32m>>> 卸载完成。\033[0m"
    exit 0
fi

# ==================== 安装逻辑 ====================

# --- 1. 信息收集 ---
read -p "请输入日常管理用户名 (例如: auser): " NEW_USERNAME
while true; do read -sp "请输入该用户的登录密码: " NEW_PASSWORD; echo; read -sp "请再次输入确认: " NEW_PASSWORD_CONFIRM; echo; if [ "$NEW_PASSWORD" = "$NEW_PASSWORD_CONFIRM" ]; then break; else echo -e "\033[31m密码不匹配\033[0m"; fi; done

read -p "请输入域名 (例如: drive.example.com): " DOMAIN_OR_IP

read -p "设置网盘应用用户名 (例如: admin): " APP_USERNAME
while true; do read -sp "设置网盘应用密码: " APP_PASSWORD; echo; read -sp "请再次输入确认: " APP_PASSWORD_CONFIRM; echo; if [ "$APP_PASSWORD" = "$APP_PASSWORD_CONFIRM" ]; then break; else echo -e "\033[31m密码不匹配\033[0m"; fi; done

echo -e "\n\033[33m>>> 开始部署 V6.0 旗舰版...\033[0m"

# --- 2. 依赖安装 ---
apt-get update -y > /dev/null 2>&1
apt-get install -y python3-pip python3-dev python3-venv debian-keyring debian-archive-keyring apt-transport-https curl gnupg zip > /dev/null 2>&1

# 创建系统用户
if ! id "$NEW_USERNAME" &>/dev/null; then
    adduser --disabled-password --gecos "" "$NEW_USERNAME" > /dev/null 2>&1
    echo "$NEW_USERNAME:$NEW_PASSWORD" | chpasswd
    usermod -aG sudo "$NEW_USERNAME"
fi

# --- 3. 安装 Caddy ---
if ! command -v caddy &> /dev/null; then
    rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
    apt-get update > /dev/null 2>&1
    apt-get install -y caddy > /dev/null 2>&1
fi

# --- 4. 部署后端 ---
PROJECT_DIR="/var/www/my_cloud_drive"
DRIVE_ROOT_DIR="/home/${NEW_USERNAME}/my_files"
mkdir -p "$PROJECT_DIR" "$DRIVE_ROOT_DIR"
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$PROJECT_DIR"
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$DRIVE_ROOT_DIR"

if [ ! -d "${PROJECT_DIR}/venv" ]; then
    su - "$NEW_USERNAME" -c "cd $PROJECT_DIR && python3 -m venv venv"
fi
su - "$NEW_USERNAME" -c "source ${PROJECT_DIR}/venv/bin/activate && pip install Flask Gunicorn" > /dev/null 2>&1

APP_SECRET_KEY=$(openssl rand -hex 32)

# --- 写入 app.py (新增批量下载逻辑) ---
echo -e "\n\033[33m>>> 写入 V6.0 后端代码...\033[0m"
cat << EOF > "${PROJECT_DIR}/app.py"
import os, json, uuid, shutil, time, zipfile
from functools import wraps
from flask import Flask, render_template, request, send_from_directory, redirect, url_for, flash, jsonify, session, send_file
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

# --- Clean up temp files older than 1 hour ---
def cleanup_temp():
    try:
        now = time.time()
        for f in os.listdir(TEMP_DIR):
            fp = os.path.join(TEMP_DIR, f)
            if os.stat(fp).st_mtime < now - 3600:
                os.remove(fp)
    except: pass

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
    cleanup_temp() # Trigger cleanup occasionally
    base_dir = app.config['DRIVE_ROOT']
    abs_path = os.path.join(base_dir, req_path)
    if not os.path.abspath(abs_path).startswith(base_dir): return "非法路径", 400
    if abs_path.startswith(TEMP_DIR): return "拒绝访问", 403

    if os.path.exists(abs_path) and os.path.isdir(abs_path):
        used_h, total_h, percent = get_disk_usage()
        try: items = sorted(os.listdir(abs_path))
        except: return "Error", 500
        file_list = []
        for item in items:
            if item.startswith('.'): continue
            full = os.path.join(abs_path, item)
            is_dir = os.path.isdir(full)
            ftype = 'dir' if is_dir else 'file'
            if not is_dir:
                l = item.lower()
                if l.endswith(('.png','.jpg','.jpeg','.gif')): ftype = 'image'
                elif l.endswith(('.mp4','.webm','.mov')): ftype = 'video'
                elif l.endswith(('.pdf')): ftype = 'pdf'
                elif l.endswith(('.txt','.md','.py','.html')): ftype = 'text'
            
            mtime = time.strftime('%Y-%m-%d %H:%M', time.localtime(os.path.getmtime(full)))
            file_list.append({'name': item, 'is_dir': is_dir, 'type': ftype, 'size': '-' if is_dir else format_bytes(os.path.getsize(full)), 'mtime': mtime})
        
        file_list.sort(key=lambda x: (not x['is_dir'], x['name'].lower()))
        return render_template('files.html', items=file_list, current_path=req_path, used=used_h, total=total_h, percent=percent, username=session['user'])
    elif os.path.exists(abs_path):
        return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path))
    return "Not Found", 404

# --- Batch Download API ---
@app.route('/api/batch_download', methods=['POST'])
@login_required
def batch_download():
    data = request.get_json()
    paths = data.get('paths', [])
    base = app.config['DRIVE_ROOT']
    
    if not paths: return jsonify({'ok': False, 'msg': '未选择文件'})

    # If single file, return direct link
    if len(paths) == 1:
        target = os.path.join(base, paths[0])
        if os.path.isfile(target):
            # Special indicator for frontend to use direct download
            return jsonify({'ok': True, 'mode': 'direct', 'url': url_for('preview_file', req_path=paths[0])})

    # Multiple files -> ZIP
    zip_name = f"download_{int(time.time())}.zip"
    zip_path = os.path.join(TEMP_DIR, zip_name)
    
    try:
        with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
            for p in paths:
                abs_p = os.path.join(base, p)
                if not os.path.abspath(abs_p).startswith(base): continue
                if os.path.isfile(abs_p):
                    zf.write(abs_p, os.path.basename(abs_p))
                elif os.path.isdir(abs_p):
                    for root, dirs, files in os.walk(abs_p):
                        for file in files:
                            fp = os.path.join(root, file)
                            arcname = os.path.relpath(fp, os.path.dirname(abs_p))
                            zf.write(fp, arcname)
        
        return jsonify({'ok': True, 'mode': 'zip', 'url': url_for('download_temp', filename=zip_name)})
    except Exception as e:
        return jsonify({'ok': False, 'msg': str(e)})

@app.route('/temp_dl/<filename>')
@login_required
def download_temp(filename):
    return send_from_directory(TEMP_DIR, filename, as_attachment=True)

# --- Upload & Operate APIs (Standard) ---
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

@app.route('/api/operate', methods=['POST'])
@login_required
def api_operate():
    data = request.get_json(); action = data.get('action'); path = data.get('path'); base = app.config['DRIVE_ROOT']
    paths = data.get('paths', [path]) if path else data.get('paths', [])
    try:
        if action == 'mkdir': os.makedirs(os.path.join(base, path, data.get('name')), exist_ok=False)
        elif action == 'delete':
            for p in paths:
                target = os.path.join(base, p)
                if not os.path.abspath(target).startswith(base) or target == base: continue
                shutil.rmtree(target) if os.path.isdir(target) else os.remove(target)
        elif action == 'rename': os.rename(os.path.join(base, path), os.path.join(os.path.dirname(os.path.join(base, path)), secure_filename(data.get('new_name'))))
        elif action == 'move':
            dest = os.path.join(base, data.get('dest')); 
            for p in paths: shutil.move(os.path.join(base, p), dest)
        elif action == 'share':
            with open(SHARES_FILE, 'r+') as f: s=json.load(f); t=uuid.uuid4().hex; s[t]=path; f.seek(0); json.dump(s,f)
            return jsonify({'ok': True, 'link': url_for('public_download', token=t, _external=True)})
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
        if not req_path: return "Expired", 404
        abs_path = os.path.join(app.config['DRIVE_ROOT'], req_path)
        return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path), as_attachment=True)
    except: return "Error", 500
EOF

# --- 写入 wsgi.py ---
echo "from app import app" > "${PROJECT_DIR}/wsgi.py"
echo 'if __name__ == "__main__": app.run()' >> "${PROJECT_DIR}/wsgi.py"

# --- 写入 V6.0 前端 (Bootstrap 5 + 任务中心) ---
echo -e "\n\033[33m>>> 写入 V6.0 前端模板...\033[0m"
mkdir -p "${PROJECT_DIR}/templates"

# Login
cat << 'EOF' > "${PROJECT_DIR}/templates/login.html"
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><title>Login</title><style>body{display:flex;align-items:center;height:100vh;background:#f5f5f5}.form-signin{width:100%;max-width:330px;margin:auto}</style></head><body class="text-center"><main class="form-signin"><form method="post"><h3>登录云盘</h3><input type="text" class="form-control mb-2" name="username" placeholder="User" required><input type="password" class="form-control mb-2" name="password" placeholder="Pass" required><button class="w-100 btn btn-lg btn-primary" type="submit">Sign in</button></form></main></body></html>
EOF

# Files (复选框 + 下载按钮 + 任务中心)
cat << 'EOF' > "${PROJECT_DIR}/templates/files.html"
<!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Cloud V6.0</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.5/font/bootstrap-icons.css"><style>:root{--sidebar-width:240px}body{min-height:100vh;background-color:#f8f9fa}.sidebar{width:var(--sidebar-width);position:fixed;top:56px;bottom:0;left:0;z-index:100;padding:0;box-shadow:inset -1px 0 0 rgba(0,0,0,.1)}.main-content{margin-left:var(--sidebar-width);padding:20px}.file-item{cursor:pointer;user-select:none}.file-item.selected{background-color:#e9ecef}#task-modal .modal-body{max-height:400px;overflow-y:auto}.drag-over{border:2px dashed #0d6efd!important;background:#f1f8ff}</style></head><body>

<header class="navbar navbar-dark sticky-top bg-dark flex-md-nowrap p-0 shadow"><a class="navbar-brand col-md-3 col-lg-2 me-0 px-3 fs-6" href="#">☁️ 私有云盘 V6.0</a>
  <div class="navbar-nav flex-row">
    <div class="nav-item text-nowrap"><button class="btn btn-dark px-3 position-relative" data-bs-toggle="modal" data-bs-target="#task-modal"><i class="bi bi-list-task"></i> 任务中心 <span class="position-absolute top-0 start-100 translate-middle p-1 bg-danger border border-light rounded-circle" id="task-badge" style="display:none"><span class="visually-hidden">New alerts</span></span></button></div>
    <div class="nav-item text-nowrap"><a class="nav-link px-3" href="{{url_for('logout')}}">退出</a></div>
  </div>
</header>

<div class="container-fluid"><div class="row">
    <nav class="col-md-3 col-lg-2 d-md-block bg-light sidebar collapse"><div class="position-sticky pt-3"><ul class="nav flex-column"><li class="nav-item"><a class="nav-link active" href="{{url_for('files_view', req_path='')}}"><i class="bi bi-hdd-network me-2"></i> 全部文件</a></li></ul><div class="mt-4 px-3"><h6>存储空间</h6><div class="progress" style="height:8px;"><div class="progress-bar" style="width:{{percent}}%;"></div></div><small class="text-muted">{{used}} / {{total}}</small></div></div></nav>

    <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4 main-content" id="main-drop-zone">
        <div class="d-flex justify-content-between align-items-center pt-3 pb-2 mb-3 border-bottom">
            <nav aria-label="breadcrumb"><ol class="breadcrumb mb-0"><li class="breadcrumb-item"><a href="{{url_for('files_view', req_path='')}}">根目录</a></li>{% if current_path %}{% for part in current_path.split('/') %}<li class="breadcrumb-item active">{{part}}</li>{% endfor %}{% endif %}</ol></nav>
            <div class="btn-group">
                <button class="btn btn-outline-primary" onclick="$('#file-input').click()"><i class="bi bi-cloud-upload"></i> 上传</button>
                <button class="btn btn-outline-success disabled" id="btn-download-selected" onclick="downloadSelected()"><i class="bi bi-download"></i> 下载选中</button>
                <button class="btn btn-outline-secondary" data-bs-toggle="modal" data-bs-target="#newFolderModal"><i class="bi bi-folder-plus"></i></button>
            </div>
        </div>
        <input type="file" id="file-input" multiple style="display:none">

        <div class="row fw-bold border-bottom pb-2 mb-2 d-none d-md-flex text-muted small">
            <div class="col-1 text-center"><input type="checkbox" class="form-check-input" id="select-all"></div>
            <div class="col-5">名称</div><div class="col-2">大小</div><div class="col-4">时间</div>
        </div>
        {% if current_path %}<div class="row py-2 border-bottom file-item" onclick="location.href='{{url_for('files_view',req_path=current_path.rsplit('/',1)[0]if'/'in current_path else'')}}'"><div class="col-12 ps-4"><i class="bi bi-arrow-90deg-up"></i> 返回上一级</div></div>{% endif %}
        
        <div id="file-container">
            {% for item in items %}
            <div class="row py-2 border-bottom file-item align-items-center" data-path="{{(current_path+'/'+item.name)if current_path else item.name}}" data-type="{{item.type}}" data-isdir="{{item.is_dir}}">
                <div class="col-1 text-center"><input type="checkbox" class="form-check-input item-check"></div>
                <div class="col-11 col-md-5 text-truncate d-flex align-items-center">
                    {% if item.is_dir %}<i class="bi bi-folder-fill text-warning me-2 fs-5"></i>
                    {% else %}<i class="bi bi-file-earmark-text text-primary me-2 fs-5"></i>{% endif %}
                    {{item.name}}
                </div>
                <div class="col-md-2 d-none d-md-block text-muted small">{{item.size}}</div>
                <div class="col-md-4 d-none d-md-block text-muted small">{{item.mtime}}</div>
            </div>
            {% else %}<div class="text-center py-5 text-muted">空目录</div>{% endfor %}
        </div>
    </main>
</div></div>

<div class="modal fade" id="task-modal" tabindex="-1"><div class="modal-dialog modal-dialog-scrollable"><div class="modal-content"><div class="modal-header"><h5 class="modal-title">任务列表</h5><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div><div class="modal-body" id="task-list"><p class="text-center text-muted">暂无任务</p></div></div></div></div>

<ul class="dropdown-menu position-fixed" id="context-menu" style="display:none;z-index:1050"><li><a class="dropdown-item" id="cm-rename">重命名</a></li><li><a class="dropdown-item text-danger" id="cm-delete">删除</a></li></ul>

<div class="modal fade" id="newFolderModal"><div class="modal-dialog"><div class="modal-content"><div class="modal-header"><h5 class="modal-title">新建文件夹</h5></div><div class="modal-body"><input type="text" class="form-control" id="newFolderName"></div><div class="modal-footer"><button class="btn btn-primary" onclick="createNewFolder()">创建</button></div></div></div></div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
<script>
const currentPath='{{current_path}}'; const CHUNK=5*1024*1024;
let tasks={}; // 任务列表

// --- 复选框逻辑 ---
function updateBtns(){
    const n=$('.item-check:checked').length;
    $('#btn-download-selected').toggleClass('disabled', n===0).html(`<i class="bi bi-download"></i> 下载选中 (${n})`);
}
$('#select-all').change(function(){$('.item-check').prop('checked', this.checked); updateBtns();});
$('.item-check').change(function(e){e.stopPropagation(); updateBtns();}); // 阻止冒泡防止触发文件点击
$('.file-item').click(function(e){
    if($(e.target).is('input')) return; // 如果点的是checkbox，忽略
    const $chk = $(this).find('.item-check');
    if(!e.ctrlKey && !e.metaKey && !$(e.target).closest('.col-1').length){ // 如果不是点选择框区域且没按Ctrl，视为打开
        const isDir=$(this).data('isdir')=='True'; const path=$(this).data('path');
        if(isDir) location.href='/'+path; else window.open('/preview/'+path);
        return;
    }
    $chk.prop('checked', !$chk.prop('checked')); updateBtns();
});

// --- 任务中心逻辑 ---
function addTask(id, name, type){
    if($('#task-list p.text-muted').length) $('#task-list').empty();
    $('#task-list').prepend(`<div class="task-item p-2 border-bottom" id="t-${id}"><div class="d-flex justify-content-between"><small>${name}</small><small class="status">${type}...</small></div><div class="progress mt-1" style="height:4px"><div class="progress-bar bg-primary" style="width:0%"></div></div></div>`);
    $('#task-badge').show();
}
function updateTask(id, percent, msg, type='primary'){
    const $t=$(`#t-${id}`); $t.find('.progress-bar').css('width',percent+'%').removeClass('bg-primary bg-success bg-danger').addClass('bg-'+type);
    if(msg) $t.find('.status').text(msg);
    if(percent>=100) setTimeout(()=>{$t.fadeOut(); checkEmptyTask();}, 3000);
}
function checkEmptyTask(){ if($('#task-list').children(':visible').length===0){ $('#task-list').html('<p class="text-center text-muted">暂无任务</p>'); $('#task-badge').hide(); } }

// --- 批量下载 ---
function downloadSelected(){
    const paths = $('.item-check:checked').map(function(){return $(this).closest('.file-item').data('path')}).get();
    if(paths.length===0) return;
    const tid = Date.now(); addTask(tid, `批量下载 (${paths.length}项)`, '打包中');
    
    // 打开任务中心给用户看
    const modal = new bootstrap.Modal(document.getElementById('task-modal')); modal.show();

    $.ajax({
        url: '/api/batch_download', type: 'POST', contentType: 'application/json',
        data: JSON.stringify({paths: paths}),
        success: function(res){
            if(res.ok){
                updateTask(tid, 100, '准备就绪', 'success');
                window.location.href = res.url; // 触发浏览器下载
            } else { updateTask(tid, 100, '失败: '+res.msg, 'danger'); }
        },
        error: function(){ updateTask(tid, 100, '网络错误', 'danger'); }
    });
}

// --- 上传逻辑 (对接任务中心) ---
$('#file-input').change(e => handleFiles(e.target.files));
$('#main-drop-zone').on('dragover',e=>{e.preventDefault();$(this).addClass('drag-over')}).on('drop',e=>{e.preventDefault();$(this).removeClass('drag-over');handleFiles(e.originalEvent.dataTransfer.files)});

async function handleFiles(files){
    if(!files.length) return;
    const modal = new bootstrap.Modal(document.getElementById('task-modal')); modal.show();
    for(let f of files) await uploadOne(f);
    location.reload();
}
async function uploadOne(file){
    const tid=Date.now()+Math.random(); addTask(tid, file.name, '等待中');
    let uploaded=0;
    try{const r=await $.ajax({url:'/api/upload_check',type:'POST',contentType:'application/json',data:JSON.stringify({filename:file.name,totalSize:file.size,path:currentPath})});uploaded=r.uploaded;}catch(e){}
    if(uploaded>=file.size){ updateTask(tid, 100, '秒传成功', 'success'); return; }
    
    while(uploaded<file.size){
        const chunk=file.slice(uploaded,uploaded+CHUNK);const fd=new FormData();fd.append('file',chunk);fd.append('filename',file.name);fd.append('path',currentPath);fd.append('totalSize',file.size);
        try{
            updateTask(tid, (uploaded/file.size)*100, '上传中...');
            const res=await $.ajax({url:'/api/upload_chunk',type:'POST',data:fd,processData:false,contentType:false});
            if(res.status==='done'||res.status==='chunk_saved'){uploaded+=chunk.size;}else throw 1;
        }catch(e){ await new Promise(r=>setTimeout(r,3000)); }
    }
    updateTask(tid, 100, '完成', 'success');
}

// --- 通用操作 (右键菜单/新建) ---
function operate(a,d){return $.ajax({url:'/api/operate',type:'POST',contentType:'application/json',data:JSON.stringify({action:a,...d})}).then(r=>{if(r.ok)location.reload();else alert(r.msg)})}
$('.file-item').on('contextmenu', function(e){
    e.preventDefault(); $('.item-check').prop('checked',false); $(this).find('.item-check').prop('checked',true); updateBtns();
    $('#context-menu').css({top:e.pageY,left:e.pageX}).show();
    const path=$(this).data('path');
    $('#cm-rename').off().click(()=>{const n=prompt("新名称:",path.split('/').pop());if(n)operate('rename',{path,new_name:n})});
    $('#cm-delete').off().click(()=>{if(confirm("确定删除?"))operate('delete',{paths:[path]})});
    return false;
});
$(document).click(()=>$('#context-menu').hide());
function createNewFolder(){const n=$('#newFolderName').val();if(n)operate('mkdir',{path:currentPath,name:n});}
</script></body></html>
EOF
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$PROJECT_DIR"

# --- 5. 配置与重启 ---
echo -e "\n\033[33m>>> 重新配置服务...\033[0m"

# Systemd
cat << EOF > /etc/systemd/system/my_cloud_drive.service
[Unit]
Description=Cloud Drive V6
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
ExecStart=${PROJECT_DIR}/venv/bin/gunicorn --workers 4 --timeout 600 --bind unix:${PROJECT_DIR}/my_cloud_drive.sock -m 007 wsgi:app
[Install]
WantedBy=multi-user.target
EOF

# Caddy
cat << EOF > /etc/caddy/Caddyfile
${DOMAIN_OR_IP} {
    request_body { max_size 10GB }
    encode gzip
    reverse_proxy unix/${PROJECT_DIR}/my_cloud_drive.sock {
        transport http { response_header_timeout 600s }
    }
}
EOF

systemctl daemon-reload
systemctl enable my_cloud_drive
systemctl restart my_cloud_drive
systemctl enable caddy
systemctl restart caddy

echo -e "\n\033[32m=============================================\033[0m"
echo -e "  V6.0 旗舰版 部署完成！"
echo -e "  访问: https://${DOMAIN_OR_IP}"
echo -e "  功能: 批量下载、任务中心弹窗、卸载选项已就绪。"
echo -e "\033[32m=============================================\033[0m"

#!/bin/bash

# ==============================================================================
#           个人网盘 V13.0 - 开发者重构版 (Developer Edition)
#
# [ 核心架构 ]
#   Backend: Python Flask + Gunicorn + Werkzeug (ProxyFix)
#   Frontend: Bootstrap 5 + jQuery + Native File API
#   Server: Caddy 2 (Automatic HTTPS / HTTP/3)
#   Storage: Local Filesystem + JSON Database
#
# [ 修复清单 ]
#   1. Fix: 下载按钮路径拼接逻辑重写 (后端下发 path)
#   2. Fix: 三点菜单 z-index 层级问题及事件委托机制
#   3. Fix: 分享链接 scheme 识别问题 (强制 HTTPS)
#   4. Fix: 更新模式下的 config.env 读取优先级修正
# ==============================================================================

# --- 全局变量与颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_DIR="/var/www/my_cloud_drive"
CONFIG_FILE="${PROJECT_DIR}/config.env"

# --- 权限检查 ---
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[Error] 必须使用 Root 权限运行此脚本。${NC}"
    exit 1
fi

# --- 界面头部 ---
clear
echo -e "${BLUE}#########################################################${NC}"
echo -e "${BLUE}#           个人网盘 V13.0 开发者重构版部署脚本         #${NC}"
echo -e "${BLUE}#########################################################${NC}"
echo -e "1. 安装 / 升级 (智能保留数据与账号)"
echo -e "2. 彻底卸载 (删除所有程序与配置)"
echo -e "3. 仅修复 Caddy (如果网站打不开选这个)"
echo -e "---------------------------------------------------------"
read -p "请选择操作 [1-3]: " ACTION

# ==============================================================================
# [模块 1] 卸载逻辑
# ==============================================================================
if [ "$ACTION" == "2" ]; then
    echo -e "\n${YELLOW}>>> [卸载] 正在停止服务...${NC}"
    systemctl stop my_cloud_drive caddy 2>/dev/null
    systemctl disable my_cloud_drive caddy 2>/dev/null
    
    echo -e ">>> [卸载] 删除系统服务配置..."
    rm -f /etc/systemd/system/my_cloud_drive.service
    rm -f /etc/caddy/Caddyfile
    
    echo -e ">>> [卸载] 删除程序文件 (保留用户数据)..."
    # 只删除代码，不删数据目录
    rm -rf "$PROJECT_DIR"
    
    echo -e ">>> [卸载] 卸载 Caddy 软件..."
    apt-get purge -y caddy >/dev/null 2>&1
    rm -rf /etc/caddy /var/lib/caddy /root/.local/share/caddy
    
    echo -e "${GREEN}[Success] 卸载完成。您的文件保留在 /home/{user}/my_files${NC}"
    exit 0
fi

# ==============================================================================
# [模块 2] 环境检测与配置读取
# ==============================================================================
echo -e "\n${YELLOW}>>> [Step 1/6] 初始化配置...${NC}"

# 1. 尝试读取旧配置
if [ -f "$CONFIG_FILE" ]; then
    echo -e "${GREEN} -> 检测到配置文件 config.env，正在加载...${NC}"
    source "$CONFIG_FILE"
    IS_UPDATE=true
else
    # 尝试从旧系统探测
    DETECTED_USER=$(ls -ld /home/*/my_files 2>/dev/null | awk '{print $3}' | head -n 1)
    DETECTED_DOMAIN=$(grep "^\S\+" /etc/caddy/Caddyfile 2>/dev/null | head -n 1 | sed 's/{//')
    
    if [ -n "$DETECTED_USER" ] && [ -n "$DETECTED_DOMAIN" ]; then
        echo -e "${GREEN} -> 检测到旧版环境，尝试自动沿用...${NC}"
        sys_user=$DETECTED_USER
        app_domain=$DETECTED_DOMAIN
        IS_UPDATE=true
    else
        IS_UPDATE=false
    fi
fi

# 2. 补全缺失配置
if [ -z "$sys_user" ]; then
    echo -e "\n我们需要一个 Linux 普通用户来运行后端程序 (安全最佳实践)。"
    read -p "请输入系统用户名 (例如: sijuly): " sys_user
    # 创建系统用户
    if ! id "$sys_user" &>/dev/null; then 
        echo " -> 创建系统用户 $sys_user ..."
        adduser --disabled-password --gecos "" "$sys_user" >/dev/null
    fi
fi

if [ -z "$app_domain" ]; then
    echo -e "\n请输入您的域名 (例如: cloud.example.com)"
    echo -e "注意：请确保域名已解析到本机 IP，否则 SSL 申请会失败。"
    read -p "域名: " app_domain
fi

if [ -z "$app_user" ]; then
    echo -e "\n请设置网盘网页端的登录账号"
    read -p "账号 (默认 admin): " app_user
    [ -z "$app_user" ] && app_user="admin"
fi

# 只有在非更新模式，或者强制重置时才询问密码
if [ "$IS_UPDATE" = false ]; then
    echo -e "\n请设置网盘网页端的登录密码"
    read -sp "密码: " app_pass; echo
else
    echo -e " -> 检测到更新模式，将保留原有密码。"
fi

# 3. 写入新配置
mkdir -p "$PROJECT_DIR"
cat << EOF > "$CONFIG_FILE"
sys_user="$sys_user"
app_domain="$app_domain"
app_user="$app_user"
EOF

# ==============================================================================
# [模块 3] 端口清理与依赖安装
# ==============================================================================
echo -e "\n${YELLOW}>>> [Step 2/6] 环境准备...${NC}"

# 强力端口清理
echo " -> 检查端口占用..."
killall nginx apache2 caddy gunicorn 2>/dev/null
# 使用 fuser 强制释放 80/443
if command -v fuser &> /dev/null; then
    fuser -k 80/tcp 2>/dev/null
    fuser -k 443/tcp 2>/dev/null
fi

echo " -> 安装系统依赖 (Python3, Pip, Tools)..."
apt-get update -y >/dev/null 2>&1
apt-get install -y python3-pip python3-dev python3-venv debian-keyring debian-archive-keyring apt-transport-https curl gnupg zip lsof >/dev/null 2>&1

# Caddy 安装逻辑
if ! command -v caddy &> /dev/null || [ "$ACTION" == "3" ]; then
    echo " -> 安装/修复 Caddy..."
    rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt-get update >/dev/null 2>&1
    apt-get install -y caddy >/dev/null 2>&1
fi

if [ "$ACTION" == "3" ]; then
    echo -e "${GREEN}Caddy 修复完成，请尝试重启服务。${NC}"
    exit 0
fi

# ==============================================================================
# [模块 4] 部署 Python 后端
# ==============================================================================
echo -e "\n${YELLOW}>>> [Step 3/6] 部署后端...${NC}"

DRIVE_ROOT_DIR="/home/${sys_user}/my_files"
mkdir -p "$PROJECT_DIR" "$DRIVE_ROOT_DIR" "${DRIVE_ROOT_DIR}/.trash" "${DRIVE_ROOT_DIR}/.temp_uploads"
chown -R "$sys_user:$sys_user" "$PROJECT_DIR" "$DRIVE_ROOT_DIR"

# 虚拟环境
if [ ! -d "${PROJECT_DIR}/venv" ]; then
    su - "$sys_user" -c "cd $PROJECT_DIR && python3 -m venv venv"
fi
su - "$sys_user" -c "source ${PROJECT_DIR}/venv/bin/activate && pip install Flask Gunicorn Werkzeug" >/dev/null 2>&1

APP_SECRET=$(openssl rand -hex 32)

# 密码逻辑：如果是更新且用户没输新密码，则从旧 app.py 读取 hash
PASS_CODE_LINE="APP_PASS_HASH = generate_password_hash('${app_pass}')"
if [ "$IS_UPDATE" = true ] && [ -z "$app_pass" ]; then
    OLD_HASH=$(grep "APP_PASS_HASH =" "${PROJECT_DIR}/app.py" 2>/dev/null)
    if [ -n "$OLD_HASH" ]; then
        PASS_CODE_LINE="$OLD_HASH"
    fi
fi

# 写入 app.py
cat << EOF > "${PROJECT_DIR}/app.py"
import os, json, uuid, shutil, time, zipfile
from functools import wraps
from flask import Flask, render_template, request, send_from_directory, redirect, url_for, flash, jsonify, session
from werkzeug.utils import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.middleware.proxy_fix import ProxyFix

app = Flask(__name__)
# 修复反向代理下的 Scheme 识别问题 (http -> https)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

app.config['SECRET_KEY'] = '${APP_SECRET}'
DRIVE_ROOT = '${DRIVE_ROOT_DIR}'
TEMP_DIR = os.path.join(DRIVE_ROOT, '.temp_uploads')
TRASH_DIR = os.path.join(DRIVE_ROOT, '.trash')
SHARES_FILE = os.path.join(DRIVE_ROOT, '.shares.json')
APP_USER = '${app_user}'
${PASS_CODE_LINE}

# 初始化目录
os.makedirs(DRIVE_ROOT, exist_ok=True)
os.makedirs(TEMP_DIR, exist_ok=True)
os.makedirs(TRASH_DIR, exist_ok=True)
if not os.path.exists(SHARES_FILE):
    with open(SHARES_FILE, 'w') as f: json.dump({}, f)

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'user' not in session: return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated

def format_bytes(size):
    for unit in ['B','K','M','G','T']:
        if size < 1024: return f"{size:.1f}{unit}"
        size /= 1024
    return f"{size:.1f}P"

def get_disk_usage():
    try:
        t, u, f = shutil.disk_usage(DRIVE_ROOT)
        return format_bytes(u), format_bytes(t), (u/t*100)
    except: return "0B", "0B", 0

# --- 路由部分 ---

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method=='POST':
        if request.form['username'] == APP_USER and check_password_hash(APP_PASS_HASH, request.form['password']):
            session['user'] = APP_USER
            return redirect('/')
        flash('登录失败：用户名或密码错误')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('user', None)
    return redirect('/login')

@app.route('/', defaults={'req_path': ''})
@app.route('/<path:req_path>')
@login_required
def index(req_path):
    category = request.args.get('category')
    search_query = request.args.get('q')
    items = []
    mode = 'normal'
    
    # 1. 图片分类模式
    if category == 'images':
        mode = 'filter'
        for root, dirs, files in os.walk(DRIVE_ROOT):
            if '.trash' in root or '.temp_uploads' in root: continue
            for name in files:
                if name.lower().endswith(('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg')):
                    full_path = os.path.join(root, name)
                    rel_path = os.path.relpath(full_path, DRIVE_ROOT)
                    items.append({
                        'name': name,
                        'is_dir': False,
                        'type': 'image',
                        'path': rel_path, # 关键：返回相对路径供前端直接使用
                        'size': format_bytes(os.path.getsize(full_path)),
                        'mtime': time.strftime('%Y-%m-%d', time.localtime(os.path.getmtime(full_path)))
                    })
        items.sort(key=lambda x: x['mtime'], reverse=True)

    # 2. 搜索模式
    elif search_query:
        mode = 'filter'
        for root, dirs, files in os.walk(DRIVE_ROOT):
            if '.trash' in root or '.temp_uploads' in root: continue
            for name in files + dirs:
                if search_query.lower() in name.lower():
                    full_path = os.path.join(root, name)
                    rel_path = os.path.relpath(full_path, DRIVE_ROOT)
                    is_dir = os.path.isdir(full_path)
                    items.append({
                        'name': name,
                        'is_dir': is_dir,
                        'path': rel_path, # 关键
                        'size': '-' if is_dir else format_bytes(os.path.getsize(full_path)),
                        'mtime': time.strftime('%Y-%m-%d', time.localtime(os.path.getmtime(full_path)))
                    })

    # 3. 普通目录模式
    else:
        abs_path = os.path.join(DRIVE_ROOT, req_path)
        if not os.path.exists(abs_path): return "路径不存在", 404
        
        # 如果是文件，直接提供下载
        if os.path.isfile(abs_path):
            return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path))
        
        try:
            for name in os.listdir(abs_path):
                if name.startswith('.'): continue
                full_path = os.path.join(abs_path, name)
                is_dir = os.path.isdir(full_path)
                
                # 简单文件类型判断
                ftype = 'folder' if is_dir else 'file'
                if not is_dir:
                    ext = name.lower().split('.')[-1]
                    if ext in ['jpg','png','jpeg','gif']: ftype='image'
                    elif ext in ['mp4','mov','avi','mkv']: ftype='video'
                    elif ext in ['zip','rar','7z']: ftype='zip'
                
                items.append({
                    'name': name,
                    'is_dir': is_dir,
                    'type': ftype,
                    'size': '-' if is_dir else format_bytes(os.path.getsize(full_path)),
                    'mtime': time.strftime('%Y-%m-%d', time.localtime(os.path.getmtime(full_path)))
                })
            items.sort(key=lambda x: (not x['is_dir'], x['name'].lower()))
        except Exception as e:
            print(f"Error reading dir: {e}")

    used, total, pct = get_disk_usage()
    return render_template('files.html', items=items, current_path=req_path, used=used, total=total, percent=pct, mode=mode)

@app.route('/api/operate', methods=['POST'])
@login_required
def operate():
    data = request.get_json()
    action = data.get('action')
    paths = data.get('paths', [data.get('path')]) # 支持多选
    
    try:
        if action == 'mkdir':
            os.makedirs(os.path.join(DRIVE_ROOT, data.get('path'), data.get('name')))
            
        elif action == 'delete':
            for p in paths:
                src = os.path.join(DRIVE_ROOT, p)
                if not os.path.exists(src): continue
                if '.trash' in src:
                    shutil.rmtree(src) if os.path.isdir(src) else os.remove(src)
                else:
                    # 移入回收站
                    shutil.move(src, os.path.join(TRASH_DIR, os.path.basename(p) + "_" + str(int(time.time()))))
                    
        elif action == 'rename':
            src = os.path.join(DRIVE_ROOT, data.get('path'))
            dst = os.path.join(os.path.dirname(src), data.get('new_name'))
            os.rename(src, dst)
            
        elif action == 'move':
            dest_dir = os.path.join(DRIVE_ROOT, data.get('dest'))
            for p in paths:
                src = os.path.join(DRIVE_ROOT, p)
                shutil.move(src, dest_dir)
                
        elif action == 'batch_download':
            # 单文件：直接返回下载链接
            if len(paths) == 1 and os.path.isfile(os.path.join(DRIVE_ROOT, paths[0])):
                return jsonify({'ok': True, 'mode': 'direct', 'url': url_for('index', req_path=paths[0])})
            
            # 多文件：打包
            zname = f"download_{int(time.time())}.zip"
            zpath = os.path.join(TEMP_DIR, zname)
            with zipfile.ZipFile(zpath, 'w') as zf:
                for p in paths:
                    ap = os.path.join(DRIVE_ROOT, p)
                    if os.path.isfile(ap):
                        zf.write(ap, os.path.basename(ap))
                    else:
                        for r, d, f in os.walk(ap):
                            for fil in f:
                                zf.write(os.path.join(r, fil), os.path.relpath(os.path.join(r, fil), os.path.dirname(ap)))
            return jsonify({'ok': True, 'mode': 'zip', 'url': url_for('temp_dl', filename=zname)})
            
        elif action == 'share':
            with open(SHARES_FILE, 'r+') as f:
                shares = json.load(f)
                token = uuid.uuid4().hex
                shares[token] = paths[0] # 暂时只支持单文件分享
                f.seek(0)
                json.dump(shares, f)
                f.truncate()
            return jsonify({'ok': True, 'link': url_for('public_download', token=token, _external=True)})
            
        return jsonify({'ok': True})
    except Exception as e:
        return jsonify({'ok': False, 'msg': str(e)})

@app.route('/temp_dl/<filename>')
def temp_dl(filename):
    return send_from_directory(TEMP_DIR, filename, as_attachment=True)

@app.route('/s/<token>')
def public_download(token):
    try:
        with open(SHARES_FILE, 'r') as f: shares = json.load(f)
        req_path = shares.get(token)
        if not req_path: return "链接失效", 404
        abs_path = os.path.join(DRIVE_ROOT, req_path)
        if not os.path.exists(abs_path): return "文件已被删除", 404
        return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path), as_attachment=True)
    except: return "Server Error", 500

# --- 上传相关 ---
@app.route('/api/upload_check', methods=['POST'])
@login_required
def up_check():
    d = request.json
    id = secure_filename(f"{d['path']}_{d['filename']}_{d['totalSize']}")
    tf = os.path.join(TEMP_DIR, id)
    return jsonify({'uploaded': os.path.getsize(tf) if os.path.exists(tf) else 0})

@app.route('/api/upload_chunk', methods=['POST'])
@login_required
def up_chunk():
    f = request.files['file']
    d = request.form
    id = secure_filename(f"{d['path']}_{d['filename']}_{d['totalSize']}")
    tf = os.path.join(TEMP_DIR, id)
    with open(tf, 'ab') as fp:
        fp.write(f.read())
    
    if os.path.getsize(tf) >= int(d['totalSize']):
        dest = os.path.join(DRIVE_ROOT, d['path'], secure_filename(d['filename']))
        # 重名处理
        c = 1
        base, ext = os.path.splitext(dest)
        while os.path.exists(dest):
            dest = f"{base}_{c}{ext}"
            c += 1
        shutil.move(tf, dest)
        return jsonify({'status': 'done'})
    return jsonify({'status': 'ok'})

if __name__ == '__main__':
    app.run()
EOF

# WSGI 入口
echo "from app import app" > "${PROJECT_DIR}/wsgi.py"
echo 'if __name__ == "__main__": app.run()' >> "${PROJECT_DIR}/wsgi.py"

# ==============================================================================
# [模块 5] 部署前端 (展开代码以便维护)
# ==============================================================================
echo -e "\n${YELLOW}>>> [Step 4/6] 部署前端资源...${NC}"
mkdir -p "${PROJECT_DIR}/templates"

# --- Login HTML ---
cat << 'EOF' > "${PROJECT_DIR}/templates/login.html"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>云盘登录</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body { background: #f0f2f5; height: 100vh; display: flex; align-items: center; justify-content: center; }
        .card { width: 360px; border: none; box-shadow: 0 8px 24px rgba(0,0,0,0.1); border-radius: 12px; }
        .btn-primary { background: #06a7ff; border: none; }
    </style>
</head>
<body>
    <div class="card p-4">
        <h4 class="text-center mb-4">云盘登录</h4>
        <form method="post">
            <div class="mb-3">
                <input type="text" name="username" class="form-control" placeholder="账号" required>
            </div>
            <div class="mb-3">
                <input type="password" name="password" class="form-control" placeholder="密码" required>
            </div>
            <button class="btn btn-primary w-100 py-2">立即登录</button>
            {% with messages = get_flashed_messages() %}
            {% if messages %}
                <div class="alert alert-danger mt-3 p-2 small">{{ messages[0] }}</div>
            {% endif %}
            {% endwith %}
        </form>
    </div>
</body>
</html>
EOF

# --- Files HTML (核心修复: JS 事件委托) ---
cat << 'EOF' > "${PROJECT_DIR}/templates/files.html"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>我的云盘</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.5/font/bootstrap-icons.css">
    <style>
        :root { --sidebar-width: 240px; --primary: #06a7ff; --bg: #f7f9fc; }
        body { font-family: -apple-system, "PingFang SC", sans-serif; background: var(--bg); height: 100vh; overflow: hidden; }
        
        .sidebar { width: var(--sidebar-width); background: #fff; height: 100%; position: fixed; border-right: 1px solid #eee; display: flex; flex-direction: column; }
        .nav-item { padding: 12px 20px; border-radius: 8px; cursor: pointer; color: #555; display: flex; align-items: center; margin: 4px 10px; }
        .nav-item:hover { background: #f5f5f5; }
        .nav-item.active { background: #e6f7ff; color: var(--primary); font-weight: 500; }
        
        .main-content { margin-left: var(--sidebar-width); height: 100%; display: flex; flex-direction: column; background: #fff; }
        
        /* 列表样式 */
        .file-list-header { display: flex; padding: 10px 24px; color: #888; font-size: 12px; border-bottom: 1px solid #f9f9f9; background: #fafafa; }
        .file-row { display: flex; padding: 12px 24px; border-bottom: 1px solid #fcfcfc; align-items: center; cursor: pointer; transition: 0.1s; }
        .file-row:hover { background: #f0faff; }
        .file-row.selected { background: #e6f7ff; }
        
        .col-check { width: 40px; }
        .col-name { flex: 1; display: flex; align-items: center; overflow: hidden; }
        .col-actions { width: 140px; opacity: 0; transition: .2s; display: flex; gap: 8px; justify-content: flex-end; }
        .file-row:hover .col-actions { opacity: 1; }
        .col-size { width: 100px; text-align: right; color: #999; font-size: 13px; }
        .col-date { width: 150px; text-align: right; color: #999; font-size: 13px; margin-left: 20px; }
        
        .action-btn { color: #666; font-size: 16px; padding: 4px; border-radius: 4px; }
        .action-btn:hover { color: var(--primary); background: #dcefff; }
        
        /* 弹出层 */
        #pop-menu { position: fixed; background: #fff; box-shadow: 0 4px 12px rgba(0,0,0,0.15); border-radius: 8px; z-index: 1050; display: none; width: 120px; padding: 5px 0; }
        .pop-item { padding: 8px 15px; cursor: pointer; font-size: 13px; }
        .pop-item:hover { background: #f5f5f5; color: var(--primary); }
        
        #task-panel { position: fixed; bottom: 20px; right: 20px; width: 340px; background: #fff; box-shadow: 0 5px 20px rgba(0,0,0,0.15); border-radius: 8px; z-index: 1050; display: none; }
        .task-list { max-height: 250px; overflow-y: auto; }
        .task-item { padding: 10px; border-bottom: 1px solid #f9f9f9; font-size: 12px; }
    </style>
</head>
<body>

<div class="sidebar">
    <div class="p-4 fw-bold fs-5 text-primary"><i class="bi bi-cloud-check-fill me-2"></i>我的云盘</div>
    <div class="nav-item {% if mode=='normal' and current_path!='.trash' %}active{% endif %}" onclick="location.href='/'"><i class="bi bi-folder2-open me-2"></i>全部文件</div>
    <div class="nav-item {% if mode=='filter' %}active{% endif %}" onclick="location.href='/?category=images'"><i class="bi bi-images me-2"></i>我的图片</div>
    <div class="nav-item" onclick="$('#task-panel').toggle()"><i class="bi bi-arrow-left-right me-2"></i>传输列表</div>
    <div class="nav-item {% if current_path=='.trash' %}active{% endif %}" onclick="location.href='/.trash'"><i class="bi bi-trash3 me-2"></i>回收站</div>
    <div style="flex:1"></div>
    <div class="p-4 border-top">
        <div class="d-flex justify-content-between small text-muted mb-1"><span>{{used}}/{{total}}</span><span>{{percent|round}}%</span></div>
        <div class="progress" style="height:6px"><div class="progress-bar bg-primary" style="width:{{percent}}%"></div></div>
    </div>
</div>

<div class="main-content" id="drop-zone">
    <div class="d-flex justify-content-between align-items-center p-3 border-bottom">
        <div class="d-flex align-items-center gap-2">
            {% if current_path != '.trash' and current_path != '我的图片' %}
            <button class="btn btn-primary rounded-pill px-4 btn-sm" onclick="$('#file-input').click()"><i class="bi bi-cloud-upload me-1"></i>上传</button>
            <button class="btn btn-light rounded-pill px-3 btn-sm" onclick="createFolder()"><i class="bi bi-folder-plus me-1"></i>新建</button>
            <button class="btn btn-light rounded-pill px-3 btn-sm" id="btn-dl" style="display:none" onclick="batchDownload()"><i class="bi bi-download me-1"></i>下载</button>
            <button class="btn btn-light rounded-pill px-3 btn-sm text-danger" id="btn-del" style="display:none" onclick="batchDelete()"><i class="bi bi-trash me-1"></i>删除</button>
            {% endif %}
            <div class="ms-3 small text-muted">{{current_path}}</div>
        </div>
        <div><input type="text" class="form-control rounded-pill btn-sm" style="width:200px;background:#f9f9f9" placeholder="搜索..." onkeyup="if(event.key==='Enter')location.href='/?q='+this.value"></div>
    </div>

    <div class="file-list-header">
        <div class="col-check"><input type="checkbox" id="sel-all"></div>
        <div class="col-name">文件名</div>
        <div class="col-actions"></div>
        <div class="col-size">大小</div>
        <div class="col-date">修改日期</div>
    </div>

    <div class="flex-grow-1 overflow-auto">
        {% for item in items %}
        <div class="file-row" data-path="{{item.name if not current_path or mode=='filter' else current_path+'/'+item.name}}" data-isdir="{{item.is_dir}}">
            <div class="col-check"><input type="checkbox" class="file-chk"></div>
            <div class="col-name file-click-area">
                <i class="bi {% if item.is_dir %}bi-folder-fill text-warning{% elif item.type=='image' %}bi-file-earmark-image-fill text-primary{% else %}bi-file-earmark-text-fill text-secondary{% endif %} fs-4 me-2"></i>
                {{item.name}}
            </div>
            <div class="col-actions">
                <i class="bi bi-share action-btn btn-share" title="分享"></i>
                <i class="bi bi-download action-btn btn-download" title="下载"></i>
                <i class="bi bi-three-dots action-btn btn-more" title="更多"></i>
            </div>
            <div class="col-size">{{item.size}}</div>
            <div class="col-date">{{item.mtime}}</div>
        </div>
        {% else %}
        <div class="text-center mt-5 text-muted">
            <i class="bi bi-cloud display-1 opacity-25"></i>
            <p class="mt-3">暂无文件</p>
        </div>
        {% endfor %}
    </div>
</div>

<input type="file" id="file-input" multiple style="display:none">

<div id="pop-menu">
    <div class="pop-item" data-act="move">移动到...</div>
    <div class="pop-item" data-act="rename">重命名</div>
    <div class="pop-item text-danger" data-act="delete">删除</div>
</div>

<div id="task-panel">
    <div class="p-2 border-bottom fw-bold d-flex justify-content-between">
        传输列表 <i class="bi bi-x" onclick="$('#task-panel').hide()" style="cursor:pointer"></i>
    </div>
    <div class="task-list" id="task-list"></div>
</div>

<script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
<script>
const CUR = '{{current_path}}';
let activePath = '';

// --- 1. 修复点击事件 (Event Delegation) ---
$(document).ready(function(){
    // 行点击：如果是点文字区域 -> 打开；如果是空白处 -> 选中
    $(document).on('click', '.file-row', function(e){
        if($(e.target).closest('.file-click-area').length){
            openItem($(this).data('path'), $(this).data('isdir'));
            return;
        }
        if($(e.target).closest('.col-actions, input').length) return;
        const c = $(this).find('.file-chk');
        c.prop('checked', !c.prop('checked'));
        updateBtns();
    });

    // 复选框变化
    $(document).on('change', '.file-chk', updateBtns);
    $('#sel-all').change(function(){ $('.file-chk').prop('checked', this.checked); updateBtns(); });

    // 按钮点击 (阻止冒泡)
    $(document).on('click', '.btn-download', function(e){ e.stopPropagation(); downloadOne($(this)); });
    $(document).on('click', '.btn-share', function(e){ e.stopPropagation(); shareOne($(this)); });
    $(document).on('click', '.btn-more', function(e){ e.stopPropagation(); showMenu(e, $(this)); });

    // 菜单操作
    $('.pop-item').click(function(){
        $('#pop-menu').hide();
        const act = $(this).data('act');
        if(act=='rename'){ const n=prompt("新名称:", activePath.split('/').pop()); if(n) api('rename',{path:activePath,new_name:n}).then(()=>location.reload()); }
        if(act=='delete'){ if(confirm('删除?')) api('delete',{paths:[activePath]}).then(()=>location.reload()); }
        if(act=='move'){ const d=prompt("目标文件夹:"); if(d) api('move',{paths:[activePath],dest:d}).then(()=>location.reload()); }
    });

    $(document).click(function(e){ if(!$(e.target).closest('.btn-more, #pop-menu').length) $('#pop-menu').hide(); });
});

function updateBtns(){
    const n = $('.file-chk:checked').length;
    $('#btn-dl, #btn-del').toggle(n > 0);
    $('.file-row').removeClass('selected');
    $('.file-chk:checked').closest('.file-row').addClass('selected');
}

// 修复：路径处理
function openItem(p, isDir){
    let final = p;
    // 如果是过滤模式(图片/搜索)，后端返回的已经是相对路径，无需拼接 CUR
    // 如果是普通模式，且点击的只是文件名，需拼接 CUR
    if(CUR && CUR!='我的图片' && CUR!='搜索结果' && !p.includes('/')) final = CUR + '/' + p;
    if(isDir) location.href = '/' + final; else window.open('/' + final);
}

// 修复：单文件下载
function downloadOne(el){
    let p = el.closest('.file-row').data('path');
    if(CUR && !p.includes('/') && CUR!='我的图片' && CUR!='搜索结果') p = CUR + '/' + p;
    window.open('/' + p);
}

// 修复：批量下载
function batchDownload(){
    const paths = $('.file-chk:checked').map((i,el)=>$(el).closest('.file-row').data('path')).get();
    if(!paths.length) return;
    if(paths.length === 1 && paths[0].indexOf('.') > 0) { window.open('/' + paths[0]); return; }
    
    $('#task-panel').show();
    addTask('zip', '打包中...', 0);
    api('batch_download', {paths: paths}).then(res => {
        if(res.ok) { updateTask('zip', 100, '完成'); location.href = res.url; }
        else alert('打包失败');
    });
}

// 修复：分享链接
function shareOne(el){
    let p = el.closest('.file-row').data('path');
    api('share', {paths: [p]}).then(res => {
        if(res.ok) prompt("分享链接:", res.link);
    });
}

function showMenu(e, el){
    activePath = el.closest('.file-row').data('path');
    const r = el[0].getBoundingClientRect();
    $('#pop-menu').css({top: r.bottom + 5, left: r.left - 80}).show();
}

function api(act, dat){ return $.ajax({url:'/api/operate', type:'POST', contentType:'application/json', data:JSON.stringify({action:act, ...dat})}); }
function createFolder(){ const n=prompt("文件夹名:"); if(n) api('mkdir',{path:CUR,name:n}).then(()=>location.reload()); }
function batchDelete(){ const ps=$('.file-chk:checked').map((i,e)=>$(e).closest('.file-row').data('path')).get(); if(confirm('删除?')) api('delete',{paths:ps}).then(()=>location.reload()); }

// 上传 (带速度显示)
$('#file-input').change(async function(e){
    $('#task-panel').show();
    for(let f of e.target.files) await uploadOne(f);
    location.reload();
});

async function uploadOne(f){
    const id = Date.now();
    $('#task-list').prepend(\`<div class="task-item" id="\${id}"><div>\${f.name} <span class="pct">0%</span></div><div class="progress" style="height:4px"><div class="progress-bar" style="width:0%"></div></div><div class="small text-muted speed">等待...</div></div>\`);
    
    let uploaded = 0;
    try { uploaded = (await $.ajax({url:'/api/upload_check', type:'POST', contentType:'application/json', data:JSON.stringify({filename:f.name, totalSize:f.size, path:CUR})})).uploaded; } catch(e){}
    if(uploaded >= f.size) { updateTask(id, 100, '秒传'); return; }

    let st = Date.now(), sl = uploaded;
    while(uploaded < f.size){
        const c = f.slice(uploaded, uploaded + 5*1024*1024);
        const fd = new FormData();
        fd.append('file', c); fd.append('filename', f.name); fd.append('path', CUR); fd.append('totalSize', f.size);
        await $.ajax({url:'/api/upload_chunk', type:'POST', data:fd, processData:false, contentType:false});
        uploaded += c.size;
        
        const e = (Date.now() - st) / 1000;
        if(e > 0.5 || uploaded == f.size){
            const s = (uploaded - sl) / e;
            updateTask(id, (uploaded/f.size)*100, \`\${fmtSp(s)} - 剩 \${fmtTm((f.size-uploaded)/s)}\`);
        }
    }
    updateTask(id, 100, '完成');
}

function updateTask(id, p, t){
    const e = $('#'+id);
    e.find('.progress-bar').css('width', p+'%');
    e.find('.pct').text(Math.round(p)+'%');
    if(t) e.find('.speed').text(t);
}
function fmtSp(b){if(b<1024)return b.toFixed(0)+'B/s';if(b<1024*1024)return(b/1024).toFixed(1)+'KB/s';return(b/1024/1024).toFixed(1)+'MB/s'}
function fmtTm(s){if(!isFinite(s))return'--';if(s<60)return s.toFixed(0)+'s';return(s/60).toFixed(0)+'m'}

// 拖拽
const dz = document.getElementById('drop-zone');
dz.addEventListener('dragover', e=>{e.preventDefault(); dz.style.background='#f0faff'});
dz.addEventListener('dragleave', e=>{e.preventDefault(); dz.style.background='#fff'});
dz.addEventListener('drop', e=>{e.preventDefault(); dz.style.background='#fff'; $('#file-input')[0].files=e.dataTransfer.files; $('#file-input').change();});
</script></body></html>
EOF
chown -R "$sys_user:$sys_user" "$PROJECT_DIR"

# ==============================================================================
# [模块 6] 服务配置与启动
# ==============================================================================
echo -e "\n${YELLOW}>>> [Step 5/6] 生成配置文件...${NC}"

# Systemd
cat << EOF > /etc/systemd/system/my_cloud_drive.service
[Unit]
Description=Cloud Drive V13.0
After=network.target
[Service]
User=${sys_user}
Group=www-data
WorkingDirectory=${PROJECT_DIR}
Environment="PATH=${PROJECT_DIR}/venv/bin"
ExecStart=${PROJECT_DIR}/venv/bin/gunicorn --workers 4 --bind unix:${PROJECT_DIR}/my_cloud_drive.sock -m 007 app:app
[Install]
WantedBy=multi-user.target
EOF

# Caddy
cat << EOF > /etc/caddy/Caddyfile
${app_domain} {
    request_body {
        max_size 20GB
    }
    encode gzip
    reverse_proxy unix/${PROJECT_DIR}/my_cloud_drive.sock {
        transport http {
            response_header_timeout 600s
        }
    }
}
EOF

echo -e "\n${YELLOW}>>> [Step 6/6] 启动与诊断...${NC}"
systemctl daemon-reload
systemctl enable my_cloud_drive caddy >/dev/null 2>&1

# 1. 启动后端
systemctl restart my_cloud_drive
if ! systemctl is-active --quiet my_cloud_drive; then
    echo -e "${RED}[Error] 后端启动失败！日志如下：${NC}"
    journalctl -u my_cloud_drive --no-pager -n 20
    exit 1
fi

# 2. 启动前端 Caddy
caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1
systemctl restart caddy
sleep 3

if ! systemctl is-active --quiet caddy; then
    echo -e "${RED}[Error] Caddy 启动失败 (通常是域名解析问题)。${NC}"
    echo -e "${YELLOW}日志诊断信息：${NC}"
    journalctl -u caddy --no-pager -n 20
    
    echo -e "\n${YELLOW}尝试自动降级到 HTTP 模式...${NC}"
    sed -i "s/${app_domain}/:80/g" /etc/caddy/Caddyfile
    systemctl restart caddy
    if systemctl is-active --quiet caddy; then
        echo -e "${GREEN}[Success] 已降级为 HTTP 启动。${NC}"
        echo -e "访问地址: http://${app_domain}"
    else
        echo -e "${RED}[Fatal] 降级启动失败，请检查端口占用或防火墙。${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}[Success] Caddy (HTTPS) 启动成功。${NC}"
    echo -e "\n${BLUE}=====================================================${NC}"
    echo -e "  🎉 个人网盘 V13.0 部署完成！"
    echo -e "  🔗 地址: https://${app_domain}"
    echo -e "  👤 账号: ${app_user}"
    echo -e "${BLUE}=====================================================${NC}"
fi

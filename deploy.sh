#!/bin/bash

# ==============================================================================
#           个人网盘 V9.0 - 终极完美版
#
# 更新日志:
# 1. [修复] 下载按钮逻辑，支持特殊字符文件名下载。
# 2. [修复] "三个小点" 菜单点击事件冒泡问题。
# 3. [修复] 分享功能现在生成真实的 /s/token 链接。
# 4. [优化] 更新模式自动读取旧密码，无需重新设置。
# 5. [优化] 安装过程自动清理端口、修复Caddy依赖，无需补丁。
# 6. [运维] 卸载选项支持彻底清除 Caddy。
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then echo -e "\033[31m必须使用 Root 运行\033[0m"; exit 1; fi

PROJECT_DIR="/var/www/my_cloud_drive"
APP_FILE="${PROJECT_DIR}/app.py"

clear
echo -e "\033[34m=====================================================\033[0m"
echo -e "\033[34m       个人网盘 V9.0 (终极完美版) 部署脚本           \033[0m"
echo -e "\033[34m=====================================================\033[0m"
echo "1. 安装 / 升级 (自动保留账号密码)"
echo "2. 彻底卸载 (包含 Caddy)"
read -p "请选择 [1-2]: " ACTION

# ==================== 卸载逻辑 ====================
if [ "$ACTION" == "2" ]; then
    echo -e "\n\033[33m>>> 正在彻底卸载...\033[0m"
    systemctl stop my_cloud_drive caddy 2>/dev/null
    systemctl disable my_cloud_drive caddy 2>/dev/null
    
    # 删除服务配置
    rm -f /etc/systemd/system/my_cloud_drive.service
    rm -f /etc/caddy/Caddyfile
    
    # 删除程序文件
    rm -rf "$PROJECT_DIR"
    
    # 卸载 Caddy
    echo "正在卸载 Caddy..."
    apt-get purge -y caddy >/dev/null 2>&1
    rm -rf /etc/caddy /var/lib/caddy
    
    echo -e "\033[32m✅ 卸载完成。\033[0m"
    echo "提示: 您的个人文件数据保留在 /home/*/my_files，如需删除请手动执行 rm -rf"
    exit 0
fi

# ==================== 安装/更新逻辑 ====================

# --- 1. 智能配置读取 ---
echo -e "\n\033[33m>>> 1. 正在检测配置...\033[0m"

# 默认值
APP_USERNAME="admin"
APP_PASSWORD="password"
DOMAIN_OR_IP=""
NEW_USERNAME=""

# 尝试从旧文件提取配置 (更新模式)
if [ -f "$APP_FILE" ]; then
    echo -e "\033[32m检测到旧版本，正在读取账号配置...\033[0m"
    # 提取系统用户名
    NEW_USERNAME=$(ls -ld /home/*/my_files 2>/dev/null | awk '{print $3}' | head -n 1)
    # 提取域名
    DOMAIN_OR_IP=$(grep "^\S\+" /etc/caddy/Caddyfile 2>/dev/null | head -n 1 | sed 's/{//')
    # 提取应用账号 (简单正则)
    EXIST_USER=$(grep "APP_USER =" "$APP_FILE" | cut -d"'" -f2)
    # 提取密码哈希的原始值比较麻烦，这里我们采取策略：
    # 如果是更新，我们直接让用户输入新密码，或者保留旧密码哈希值
    # 为了简化，V9.0 如果检测到更新，直接读取 APP_PASS_HASH 的整行代码复用
    OLD_HASH_LINE=$(grep "APP_PASS_HASH =" "$APP_FILE")
    
    if [ -n "$EXIST_USER" ]; then APP_USERNAME=$EXIST_USER; fi
    echo " - 系统用户: $NEW_USERNAME"
    echo " - 域名: $DOMAIN_OR_IP"
    echo " - 网盘账号: $APP_USERNAME"
    echo " - 密码: [已保留旧密码]"
    IS_UPDATE=true
else
    IS_UPDATE=false
fi

# 如果不是更新，或者提取失败，则询问
if [ -z "$NEW_USERNAME" ]; then
    read -p "请输入系统用户名 (例如: auser): " NEW_USERNAME
    if ! id "$NEW_USERNAME" &>/dev/null; then adduser --disabled-password --gecos "" "$NEW_USERNAME" >/dev/null; fi
fi

if [ -z "$DOMAIN_OR_IP" ]; then
    read -p "请输入域名或IP: " DOMAIN_OR_IP
fi

if [ "$IS_UPDATE" = false ]; then
    read -sp "请设置网盘登录密码: " APP_PASSWORD; echo
fi

# --- 2. 环境清理与安装 (Caddy 自动修复逻辑) ---
echo -e "\033[33m>>> 2. 清理端口并安装依赖...\033[0m"

# 强制杀掉占用的端口，防止 Caddy 启动失败
systemctl stop nginx apache2 2>/dev/null
killall nginx apache2 caddy gunicorn 2>/dev/null
fuser -k 80/tcp 2>/dev/null
fuser -k 443/tcp 2>/dev/null

apt-get update -y >/dev/null 2>&1
# 关键：安装 gnupg 防止 Caddy 安装失败
apt-get install -y python3-pip python3-dev python3-venv debian-keyring debian-archive-keyring apt-transport-https curl gnupg zip >/dev/null 2>&1

# 安装/重装 Caddy
if ! command -v caddy &> /dev/null; then
    echo "正在安装 Caddy..."
    rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt-get update >/dev/null 2>&1
    apt-get install -y caddy >/dev/null 2>&1
fi

# --- 3. 部署后端 (App.py) ---
echo -e "\033[33m>>> 3. 部署后端逻辑...\033[0m"
DRIVE_ROOT_DIR="/home/${NEW_USERNAME}/my_files"
mkdir -p "$PROJECT_DIR" "$DRIVE_ROOT_DIR" "${DRIVE_ROOT_DIR}/.trash" "${DRIVE_ROOT_DIR}/.temp_uploads"
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$PROJECT_DIR" "$DRIVE_ROOT_DIR"

if [ ! -d "${PROJECT_DIR}/venv" ]; then su - "$NEW_USERNAME" -c "cd $PROJECT_DIR && python3 -m venv venv"; fi
su - "$NEW_USERNAME" -c "source ${PROJECT_DIR}/venv/bin/activate && pip install Flask Gunicorn" >/dev/null 2>&1

APP_SECRET_KEY=$(openssl rand -hex 32)

# 构建密码部分代码
if [ "$IS_UPDATE" = true ] && [ -n "$OLD_HASH_LINE" ]; then
    PASS_CODE="$OLD_HASH_LINE" # 直接复用旧的 Hash 代码行
else
    # 新安装，生成 Hash 代码
    PASS_CODE="APP_PASS_HASH = generate_password_hash('${APP_PASSWORD}')"
fi

cat << EOF > "${PROJECT_DIR}/app.py"
import os, json, uuid, shutil, time, zipfile
from functools import wraps
from flask import Flask, render_template, request, send_from_directory, redirect, url_for, flash, jsonify, session
from werkzeug.utils import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
app.config['SECRET_KEY'] = '${APP_SECRET_KEY}'
DRIVE_ROOT = '${DRIVE_ROOT_DIR}'
TEMP_DIR = os.path.join(DRIVE_ROOT, '.temp_uploads')
TRASH_DIR = os.path.join(DRIVE_ROOT, '.trash')
SHARES_FILE = os.path.join(DRIVE_ROOT, '.shares.json')
APP_USER = '${APP_USERNAME}'
${PASS_CODE}

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
    t, u, f = shutil.disk_usage(DRIVE_ROOT)
    return format_bytes(u), format_bytes(t), (u/t*100)

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method=='POST':
        if request.form['username']==APP_USER and check_password_hash(APP_PASS_HASH, request.form['password']):
            session['user']=APP_USER; return redirect('/')
        flash('登录失败')
    return render_template('login.html')

@app.route('/logout')
def logout(): session.pop('user',None); return redirect('/login')

@app.route('/', defaults={'req_path': ''})
@app.route('/<path:req_path>')
@login_required
def index(req_path):
    category = request.args.get('category')
    search_query = request.args.get('q')
    
    # 图片模式
    if category == 'images':
        results = []
        for root, dirs, files in os.walk(DRIVE_ROOT):
            if '.trash' in root or '.temp_uploads' in root: continue
            for name in files:
                if name.lower().endswith(('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg')):
                    full_path = os.path.join(root, name)
                    rel_path = os.path.relpath(full_path, DRIVE_ROOT)
                    results.append({
                        'name': name, 'is_dir': False, 'type': 'image', 'path': rel_path,
                        'size': format_bytes(os.path.getsize(full_path)),
                        'mtime': time.strftime('%Y-%m-%d %H:%M', time.localtime(os.path.getmtime(full_path)))
                    })
        results.sort(key=lambda x: x['mtime'], reverse=True)
        used, total, pct = get_disk_usage()
        return render_template('files.html', items=results, current_path='我的图片', used=used, total=total, percent=pct, mode='filter')

    # 搜索模式
    if search_query:
        results = []
        for root, dirs, files in os.walk(DRIVE_ROOT):
            if '.trash' in root or '.temp_uploads' in root: continue
            for name in files + dirs:
                if search_query.lower() in name.lower():
                    full_path = os.path.join(root, name)
                    rel_path = os.path.relpath(full_path, DRIVE_ROOT)
                    is_dir = os.path.isdir(full_path)
                    results.append({
                        'name': name, 'is_dir': is_dir, 'path': rel_path,
                        'size': '-' if is_dir else format_bytes(os.path.getsize(full_path)),
                        'mtime': time.strftime('%Y-%m-%d %H:%M', time.localtime(os.path.getmtime(full_path)))
                    })
        used, total, pct = get_disk_usage()
        return render_template('files.html', items=results, current_path='搜索结果', used=used, total=total, percent=pct, mode='filter')

    abs_path = os.path.join(DRIVE_ROOT, req_path)
    if not os.path.exists(abs_path): return "路径不存在", 404
    
    # 修复：如果是文件，直接返回文件内容 (下载/预览)
    if os.path.isfile(abs_path):
        return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path))

    items = []
    try:
        for name in os.listdir(abs_path):
            if name.startswith('.'): continue
            full = os.path.join(abs_path, name)
            is_dir = os.path.isdir(full)
            ftype = 'folder' if is_dir else 'file'
            if not is_dir:
                ext = name.lower().split('.')[-1]
                if ext in ['jpg','png','jpeg','gif']: ftype='image'
                elif ext in ['mp4','mov','avi','mkv']: ftype='video'
                elif ext in ['zip','rar','7z','tar','gz']: ftype='zip'
                elif ext in ['doc','docx','xls','xlsx','ppt','pptx']: ftype='doc'
            items.append({
                'name': name, 'is_dir': is_dir, 'type': ftype,
                'size': '-' if is_dir else format_bytes(os.path.getsize(full)),
                'mtime': time.strftime('%Y-%m-%d %H:%M', time.localtime(os.path.getmtime(full)))
            })
        items.sort(key=lambda x: (not x['is_dir'], x['name'].lower()))
    except: pass
    
    used, total, pct = get_disk_usage()
    return render_template('files.html', items=items, current_path=req_path, used=used, total=total, percent=pct, mode='normal')

@app.route('/api/operate', methods=['POST'])
@login_required
def operate():
    data = request.get_json(); action = data.get('action')
    paths = data.get('paths', [data.get('path')])
    try:
        if action == 'mkdir':
            os.makedirs(os.path.join(DRIVE_ROOT, data.get('path'), data.get('name')))
        elif action == 'delete':
            for p in paths:
                src = os.path.join(DRIVE_ROOT, p)
                if not os.path.exists(src): continue
                if '.trash' in src: shutil.rmtree(src) if os.path.isdir(src) else os.remove(src)
                else: shutil.move(src, os.path.join(TRASH_DIR, os.path.basename(p) + "_" + str(int(time.time()))))
        elif action == 'rename':
            src = os.path.join(DRIVE_ROOT, data.get('path'))
            dst = os.path.join(os.path.dirname(src), data.get('new_name'))
            os.rename(src, dst)
        elif action == 'move':
            dest_dir = os.path.join(DRIVE_ROOT, data.get('dest'))
            for p in paths: shutil.move(os.path.join(DRIVE_ROOT, p), dest_dir)
        elif action == 'batch_download':
            zname = f"download_{int(time.time())}.zip"
            zpath = os.path.join(TEMP_DIR, zname)
            with zipfile.ZipFile(zpath,'w') as zf:
                for p in paths:
                    ap = os.path.join(DRIVE_ROOT, p)
                    if os.path.isfile(ap): zf.write(ap, os.path.basename(ap))
                    else:
                        for r,d,f in os.walk(ap):
                            for fil in f: zf.write(os.path.join(r,fil), os.path.relpath(os.path.join(r,fil), os.path.dirname(ap)))
            return jsonify({'ok':True, 'url': url_for('temp_dl', filename=zname)})
        elif action == 'share':
            # 修复：返回真实的分享链接
            with open(SHARES_FILE, 'r+') as f:
                shares=json.load(f); token=uuid.uuid4().hex; shares[token]=paths[0]
                f.seek(0); json.dump(shares, f); f.truncate()
            return jsonify({'ok': True, 'link': url_for('public_download', token=token, _external=True)})
        return jsonify({'ok': True})
    except Exception as e: return jsonify({'ok': False, 'msg': str(e)})

@app.route('/temp_dl/<filename>')
def temp_dl(filename): return send_from_directory(TEMP_DIR, filename, as_attachment=True)

@app.route('/s/<token>')
def public_download(token):
    try:
        with open(SHARES_FILE, 'r') as f: shares = json.load(f)
        req_path = shares.get(token)
        if not req_path: return "链接失效或已过期", 404
        abs_path = os.path.join(DRIVE_ROOT, req_path)
        return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path), as_attachment=True)
    except: return "Server Error", 500

@app.route('/api/upload_check', methods=['POST'])
@login_required
def up_check():
    d=request.json; id=secure_filename(f"{d['path']}_{d['filename']}_{d['totalSize']}")
    tf=os.path.join(TEMP_DIR, id); return jsonify({'uploaded': os.path.getsize(tf) if os.path.exists(tf) else 0})

@app.route('/api/upload_chunk', methods=['POST'])
@login_required
def up_chunk():
    f=request.files['file']; d=request.form; id=secure_filename(f"{d['path']}_{d['filename']}_{d['totalSize']}")
    tf=os.path.join(TEMP_DIR, id)
    with open(tf, 'ab') as fp: fp.write(f.read())
    if os.path.getsize(tf) >= int(d['totalSize']):
        dest = os.path.join(DRIVE_ROOT, d['path'], secure_filename(d['filename']))
        c=1; base,ext=os.path.splitext(dest)
        while os.path.exists(dest): dest=f"{base}_{c}{ext}"; c+=1
        shutil.move(tf, dest); return jsonify({'status':'done'})
    return jsonify({'status':'ok'})

if __name__ == '__main__': app.run()
EOF

# 创建 wsgi
echo "from app import app" > "${PROJECT_DIR}/wsgi.py"
echo 'if __name__ == "__main__": app.run()' >> "${PROJECT_DIR}/wsgi.py"

# --- 4. 部署前端 (CSS/JS 修复) ---
echo -e "\033[33m>>> 4. 部署前端...\033[0m"
mkdir -p "${PROJECT_DIR}/templates"

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
        :root { --sidebar-width: 240px; --primary-color: #06a7ff; --bg-color: #f7f9fc; --hover-bg: #f0faff; }
        body { font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif; background: var(--bg-color); height: 100vh; overflow: hidden; }
        .sidebar { width: var(--sidebar-width); background: #fff; height: 100%; position: fixed; border-right: 1px solid #eee; display: flex; flex-direction: column; }
        .logo-area { padding: 24px; font-weight: bold; font-size: 18px; display: flex; align-items: center; }
        .logo-area i { font-size: 24px; color: var(--primary-color); margin-right: 10px; }
        .nav-item { padding: 12px 20px; border-radius: 8px; cursor: pointer; color: #555; display: flex; align-items: center; margin: 0 10px 4px 10px; }
        .nav-item:hover { background-color: #f5f5f5; }
        .nav-item.active { background-color: #e6f7ff; color: var(--primary-color); font-weight: 500; }
        .nav-item i { margin-right: 12px; font-size: 18px; }
        .main-content { margin-left: var(--sidebar-width); height: 100%; display: flex; flex-direction: column; background: #fff; }
        .top-bar { padding: 16px 24px; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #f0f0f0; }
        .btn-pill { border-radius: 20px; padding: 6px 20px; font-size: 14px; border: none; transition: 0.2s; }
        .btn-primary-pill { background: var(--primary-color); color: #fff; }
        .btn-primary-pill:hover { background: #0095ea; color: #fff; }
        .btn-light-pill { background: #f0f0f0; color: #333; }
        .search-box input { border-radius: 20px; border: 1px solid #eee; padding: 6px 36px 6px 16px; width: 200px; background: #f9f9f9; }
        .file-list-header { display: flex; padding: 10px 24px; color: #888; font-size: 12px; border-bottom: 1px solid #f9f9f9; }
        .file-list-body { flex: 1; overflow-y: auto; position: relative; }
        .file-row { display: flex; padding: 12px 24px; border-bottom: 1px solid #fcfcfc; align-items: center; cursor: pointer; transition: 0.1s; }
        .file-row:hover { background-color: var(--hover-bg); }
        .file-row.selected { background-color: #e6f7ff; }
        .col-check { width: 40px; }
        .col-name { flex: 1; display: flex; align-items: center; overflow: hidden; }
        .col-actions { width: 140px; opacity: 0; transition: 0.2s; display: flex; gap: 8px; justify-content: flex-end; }
        .file-row:hover .col-actions { opacity: 1; }
        .col-size { width: 100px; text-align: right; color: #999; font-size: 13px; }
        .col-date { width: 150px; text-align: right; color: #999; font-size: 13px; margin-left: 20px; }
        .file-icon { font-size: 24px; margin-right: 12px; }
        .action-btn { color: #666; font-size: 16px; padding: 4px; border-radius: 4px; }
        .action-btn:hover { background: #dcefff; color: var(--primary-color); }
        .popover-menu { position: fixed; background: #fff; border: 1px solid #eee; box-shadow: 0 4px 12px rgba(0,0,0,0.15); border-radius: 8px; z-index: 1000; width: 120px; display: none; padding: 5px 0; }
        .popover-item { padding: 8px 15px; font-size: 13px; cursor: pointer; }
        .popover-item:hover { background: #f5f5f5; color: var(--primary-color); }
        #task-panel { position: fixed; bottom: 20px; right: 20px; width: 340px; background: #fff; box-shadow: 0 5px 20px rgba(0,0,0,0.15); border-radius: 8px; z-index: 999; display: none; }
        .task-header { padding: 12px; border-bottom: 1px solid #eee; font-weight: bold; display: flex; justify-content: space-between; }
        .task-list { max-height: 250px; overflow-y: auto; }
        .task-item { padding: 10px; border-bottom: 1px solid #f9f9f9; font-size: 12px; }
        .task-info { display: flex; justify-content: space-between; color: #666; margin-bottom: 4px; }
        .task-speed { font-size: 11px; color: #999; }
        .empty-state { text-center; margin-top: 100px; color: #999; }
        .empty-btn { margin-top: 20px; padding: 10px 30px; border-radius: 30px; background: #f0faff; color: var(--primary-color); border: 1px solid var(--primary-color); cursor: pointer; }
    </style>
</head>
<body>

<div class="sidebar">
 <div class="logo-area"><i class="bi bi-cloud-check-fill"></i> 我的云盘</div>
 <div class="nav-item {% if mode=='normal' and current_path!='.trash' %}active{% endif %}" onclick="location.href='/'"><i class="bi bi-folder2-open"></i> 全部文件</div>
 <div class="nav-item {% if mode=='filter' %}active{% endif %}" onclick="location.href='/?category=images'"><i class="bi bi-images"></i> 我的图片</div>
 <div class="nav-item" onclick="$('#task-panel').toggle()"><i class="bi bi-arrow-left-right"></i> 传输列表</div>
 <div class="nav-item {% if current_path=='.trash' %}active{% endif %}" onclick="location.href='/.trash'"><i class="bi bi-trash3"></i> 回收站</div>
 <div style="flex:1"></div><div class="p-4 border-top"><div class="d-flex justify-content-between small text-muted mb-1"><span>{{used}}/{{total}}</span><span>{{percent|round}}%</span></div><div class="progress" style="height:6px"><div class="progress-bar bg-primary" style="width:{{percent}}%"></div></div></div>
</div>

<div class="main-content" id="drop-zone">
 <div class="top-bar">
  <div class="d-flex align-items-center gap-2">{% if current_path!='.trash' and current_path!='我的图片' %}<button class="btn btn-primary-pill" onclick="$('#file-input').click()"><i class="bi bi-cloud-arrow-up"></i> 上传</button><button class="btn btn-light-pill" onclick="createFolder()"><i class="bi bi-folder-plus"></i> 新建</button><button class="btn btn-light-pill" id="btn-dl" style="display:none" onclick="batchDownload()"><i class="bi bi-download"></i> 下载选中</button><button class="btn btn-light-pill text-danger" id="btn-del" style="display:none" onclick="batchDelete()"><i class="bi bi-trash"></i> 删除</button>{% endif %}<div class="ms-3 small text-muted">{% if mode=='filter' %}<span><i class="bi bi-funnel"></i> {{current_path}}</span>{% else %}<a href="/" class="text-decoration-none text-muted">全部文件</a>{% if current_path and current_path!='.trash' %}{% for part in current_path.split('/') %}<span class="mx-1">/</span>{{part}}{% endfor %}{% endif %}{% endif %}</div></div>
  <div class="search-box position-relative"><input type="text" placeholder="搜索..." onkeyup="if(event.key==='Enter')location.href='/?q='+this.value"><i class="bi bi-search position-absolute top-50 end-0 translate-middle-y me-3 text-muted"></i></div>
 </div>
 <div class="file-list-header"><div class="col-check"><input type="checkbox" id="sel-all"></div><div class="col-name">文件名</div><div class="col-actions"></div><div class="col-size">大小</div><div class="col-date">修改日期</div></div>
 <div class="file-list-body">
  {% for item in items %}
  <div class="file-row" data-path="{{item.name if not current_path or mode=='filter' else current_path+'/'+item.name}}">
   <div class="col-check"><input type="checkbox" class="file-chk"></div>
   <div class="col-name" onclick="openItem('{{item.path if mode=='filter' else item.name}}',{{'true' if item.is_dir else 'false'}})">
    <div class="file-icon">{% if item.is_dir %}<i class="bi bi-folder-fill text-warning"></i>{% elif item.type=='image' %}<i class="bi bi-file-earmark-image-fill text-primary"></i>{% elif item.type=='video' %}<i class="bi bi-file-earmark-play-fill text-danger"></i>{% elif item.type=='zip' %}<i class="bi bi-file-earmark-zip-fill text-warning"></i>{% else %}<i class="bi bi-file-earmark-text-fill text-secondary"></i>{% endif %}</div>
    <div class="file-name-text">{{item.name}}</div>
   </div>
   <div class="col-actions"><i class="bi bi-share action-btn" title="分享" onclick="shareItem(event,this)"></i><i class="bi bi-download action-btn" title="下载" onclick="downloadItem(event,this)"></i><i class="bi bi-three-dots action-btn" title="更多" onclick="showMenu(event,this)"></i></div>
   <div class="col-size">{{item.size}}</div><div class="col-date">{{item.mtime}}</div>
  </div>
  {% else %}
  <div class="empty-state"><i class="bi bi-cloud-upload display-1 opacity-25"></i><p class="mt-3">当前文件夹为空</p>{% if current_path!='.trash' and current_path!='我的图片' %}<button class="empty-btn" onclick="$('#file-input').click()">上传文件</button>{% endif %}</div>
  {% endfor %}
 </div>
</div>
<input type="file" id="file-input" multiple style="display:none">
<div class="popover-menu" id="pop-menu"><div class="popover-item" onclick="popAction('move')">移动到...</div><div class="popover-item" onclick="popAction('rename')">重命名</div><div class="popover-item text-danger" onclick="popAction('delete')">删除</div></div>
<div id="task-panel"><div class="task-header">传输列表 <i class="bi bi-x" style="cursor:pointer" onclick="$('#task-panel').hide()"></i></div><div class="task-list" id="task-list"></div></div>

<script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
<script>
const CUR='{{current_path}}'; let active='';
// 复选框与点击逻辑
$('.file-row').click(function(e){if($(e.target).closest('.col-actions,.col-name').length)return;const c=$(this).find('.file-chk');c.prop('checked',!c.prop('checked'));updateBtns()});
$('#sel-all').change(function(){$('.file-chk').prop('checked',this.checked);updateBtns()});
function updateBtns(){const n=$('.file-chk:checked').length;$('#btn-dl,#btn-del').toggle(n>0);$('.file-row').removeClass('selected');$('.file-chk:checked').parents('.file-row').addClass('selected')}
// 打开/下载/分享
function openItem(p,d){let f=p;if(CUR&&CUR!='我的图片'&&CUR!='搜索结果'&&!p.includes('/'))f=CUR+'/'+p;if(d)location.href='/'+f;else window.open('/'+f)}
function downloadItem(e,el){e.stopPropagation();let p=$(el).parents('.file-row').data('path');if(CUR&&!p.includes('/'))p=CUR+'/'+p;window.open('/'+p)}
function shareItem(e,el){e.stopPropagation();let p=$(el).parents('.file-row').data('path');api('share',{paths:[p]}).then(r=>{if(r.ok)prompt('分享链接已生成 (请复制):',r.link)})}
function api(a,d){return $.ajax({url:'/api/operate',type:'POST',contentType:'application/json',data:JSON.stringify({action:a,...d})})}
// 菜单逻辑
function showMenu(e,el){e.stopPropagation();active=$(el).parents('.file-row').data('path');$('#pop-menu').css({top:e.clientY+10,left:e.clientX-100}).fadeIn(100);$(document).one('click',()=>$('#pop-menu').fadeOut(100))}
function popAction(a){if(a=='rename'){const n=prompt("重命名:",active.split('/').pop());if(n)api('rename',{path:active,new_name:n}).then(()=>location.reload())}if(a=='delete'){if(confirm('删除?'))api('delete',{paths:[active]}).then(()=>location.reload())}if(a=='move'){const d=prompt("目标路径:");if(d)api('move',{paths:[active],dest:d}).then(()=>location.reload())}}
// 批量操作
function createFolder(){const n=prompt("文件夹名:");if(n)api('mkdir',{path:CUR,name:n}).then(()=>location.reload())}
function batchDownload(){const ps=$('.file-chk:checked').map((i,e)=>$(e).parents('.file-row').data('path')).get();api('batch_download',{paths:ps}).then(r=>{if(r.ok)location.href=r.url})}
function batchDelete(){const ps=$('.file-chk:checked').map((i,e)=>$(e).parents('.file-row').data('path')).get();if(confirm('删除?'))api('delete',{paths:ps}).then(()=>location.reload())}
// 上传
$('#file-input').change(async function(e){$('#task-panel').show();for(let f of e.target.files)await uploadOne(f);location.reload()});
async function uploadOne(f){const id=Date.now();$('#task-list').prepend(\`<div class="task-item" id="\${id}"><div class="task-info"><span>\${f.name}</span><span class="pct">0%</span></div><div class="progress" style="height:4px"><div class="progress-bar" style="width:0%"></div></div><div class="task-speed">等待...</div></div>\`);let up=0;try{up=(await $.ajax({url:'/api/upload_check',type:'POST',contentType:'application/json',data:JSON.stringify({filename:f.name,totalSize:f.size,path:CUR})})).uploaded}catch(e){}if(up>=f.size){updateTask(id,100,'秒传');return}let st=Date.now(),sl=up;while(up<f.size){const c=f.slice(up,up+5*1024*1024);const fd=new FormData();fd.append('file',c);fd.append('filename',f.name);fd.append('path',CUR);fd.append('totalSize',f.size);await $.ajax({url:'/api/upload_chunk',type:'POST',data:fd,processData:false,contentType:false});up+=c.size;const e=(Date.now()-st)/1000;if(e>0.5||up==f.size){const s=(up-sl)/e;updateTask(id,(up/f.size)*100,\`\${fmtSp(s)} - 剩 \${fmtTm((f.size-up)/s)}\`)}}}
function updateTask(id,p,t){const e=$('#'+id);e.find('.progress-bar').css('width',p+'%');e.find('.pct').text(Math.round(p)+'%');if(t)e.find('.task-speed').text(t)}
function fmtSp(b){if(b<1024)return b.toFixed(0)+'B/s';if(b<1024*1024)return(b/1024).toFixed(1)+'K/s';return(b/1024/1024).toFixed(1)+'M/s'}
function fmtTm(s){if(!isFinite(s))return'--';if(s<60)return s.toFixed(0)+'s';return(s/60).toFixed(0)+'m'}
const dz=document.getElementById('drop-zone');dz.addEventListener('dragover',e=>{e.preventDefault();dz.style.background='#f0faff'});dz.addEventListener('dragleave',e=>{e.preventDefault();dz.style.background='#fff'});dz.addEventListener('drop',e=>{e.preventDefault();dz.style.background='#fff';$('#file-input')[0].files=e.dataTransfer.files;$('#file-input').change()});
</script></body></html>
EOF
cat << 'EOF' > "${PROJECT_DIR}/templates/login.html"
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>登录</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><style>body{background:#f0f2f5;height:100vh;display:flex;align-items:center;justify-content:center}.card{width:360px;border:none;box-shadow:0 8px 24px rgba(0,0,0,0.1);border-radius:12px}.btn-primary{background:#06a7ff;border:none}</style></head><body><div class="card p-4"><h4 class="text-center mb-4">云盘登录</h4><form method="post"><div class="mb-3"><input type="text" name="username" class="form-control" placeholder="账号" required></div><div class="mb-3"><input type="password" name="password" class="form-control" placeholder="密码" required></div><button class="btn btn-primary w-100 py-2">立即登录</button></form></div></body></html>
EOF
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$PROJECT_DIR"

# --- 5. 生成系统配置 (修复 Caddy 自动检测逻辑) ---
echo -e "\033[33m>>> 5. 生成系统服务配置...\033[0m"

# Systemd
cat << EOF > /etc/systemd/system/my_cloud_drive.service
[Unit]
Description=Cloud Drive V9.0
After=network.target
[Service]
User=${NEW_USERNAME}
Group=www-data
WorkingDirectory=${PROJECT_DIR}
Environment="PATH=${PROJECT_DIR}/venv/bin"
ExecStart=${PROJECT_DIR}/venv/bin/gunicorn --workers 4 --bind unix:${PROJECT_DIR}/my_cloud_drive.sock -m 007 app:app
[Install]
WantedBy=multi-user.target
EOF

# Caddy
cat << EOF > /etc/caddy/Caddyfile
${DOMAIN_OR_IP} {
    request_body { max_size 20GB }
    encode gzip
    reverse_proxy unix/${PROJECT_DIR}/my_cloud_drive.sock {
        transport http { response_header_timeout 600s }
    }
}
EOF

# --- 6. 启动 ---
echo -e "\033[33m>>> 6. 启动服务...\033[0m"
systemctl daemon-reload
systemctl enable my_cloud_drive caddy
systemctl restart my_cloud_drive caddy

echo -e "\n\033[32m=============================================\033[0m"
echo -e " ✅ V9.0 终极完美版 部署成功！"
echo -e " 访问: https://${DOMAIN_OR_IP}"
echo -e " 用户: ${APP_USERNAME}"
echo -e " 说明: 支持自动HTTPS、实时网速、回收站、分享链接"
echo -e "\033[32m=============================================\033[0m"

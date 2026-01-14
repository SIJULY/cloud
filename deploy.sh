#!/bin/bash

# ==============================================================================
#           一键部署 Python + Flask + Gunicorn + Caddy 个人网盘项目
#
#                    V4.0 - Caddy 特别版 (自动HTTPS + HTTP/3)
#
# 说明:
# 1. 自动安装 Caddy 并配置反向代理。
# 2. 如果输入的是域名，Caddy 会自动申请 SSL 证书并开启 HTTPS。
# 3. 如果输入的是 IP，Caddy 会自动使用 HTTP。
# 4. 默认开启 HTTP/3 (QUIC) 加速。
# ==============================================================================

# --- 检查 Root ---
if [ "$(id -u)" -ne 0 ]; then echo "必须使用 Root 运行"; exit 1; fi

# --- 1. 收集信息 ---
echo -e "\033[0;32m正在准备部署 Caddy 版网盘...\033[0m"
read -p "请输入日常管理用户名 (如: auser): " NEW_USERNAME
while true; do read -sp "请输入该用户的登录密码: " NEW_PASSWORD; echo; read -sp "请再次输入确认: " NEW_PASSWORD_CONFIRM; echo; if [ "$NEW_PASSWORD" = "$NEW_PASSWORD_CONFIRM" ]; then break; else echo "密码不匹配"; fi; done
read -p "请输入您的域名或IP (域名会自动开启HTTPS): " DOMAIN_OR_IP
read -p "请输入网盘应用登录用户名 (如: admin): " APP_USERNAME
while true; do read -sp "请输入网盘应用登录密码: " APP_PASSWORD; echo; read -sp "请再次输入确认: " APP_PASSWORD_CONFIRM; echo; if [ "$APP_PASSWORD" = "$APP_PASSWORD_CONFIRM" ]; then break; else echo "密码不匹配"; fi; done

# --- 2. 系统初始化 ---
apt-get update -y
apt-get install -y python3-pip python3-dev python3-venv debian-keyring debian-archive-keyring apt-transport-https curl

# 创建用户
if ! id "$NEW_USERNAME" &>/dev/null; then
    adduser --disabled-password --gecos "" "$NEW_USERNAME"
    echo "$NEW_USERNAME:$NEW_PASSWORD" | chpasswd
    usermod -aG sudo "$NEW_USERNAME"
fi

# --- 3. 安装 Caddy (官方源) ---
echo -e "\n\033[0;33m>>> 正在安装 Caddy Web Server...\033[0m"
# 卸载 Nginx 防止端口冲突
systemctl stop nginx 2>/dev/null
systemctl disable nginx 2>/dev/null
apt-get remove -y nginx 2>/dev/null

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update
apt-get install -y caddy

# --- 4. 部署 Python 项目 (同 V4.0) ---
echo -e "\n\033[0;33m>>> 部署 Python 后端...\033[0m"
PROJECT_DIR="/var/www/my_cloud_drive"
DRIVE_ROOT_DIR="/home/${NEW_USERNAME}/my_files"
mkdir -p "$PROJECT_DIR" "$DRIVE_ROOT_DIR"
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$DRIVE_ROOT_DIR"

if [ ! -d "${PROJECT_DIR}/venv" ]; then
    su - "$NEW_USERNAME" -c "cd $PROJECT_DIR && python3 -m venv venv"
fi
su - "$NEW_USERNAME" -c "source ${PROJECT_DIR}/venv/bin/activate && pip install Flask Gunicorn"

APP_SECRET_KEY=$(openssl rand -hex 32)

# --- 写入 app.py (V4.0 核心代码) ---
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
        flash('Auth Failed')
    return render_template('login.html')

@app.route('/logout')
def logout(): session.pop('user', None); return redirect(url_for('login'))

@app.route('/', defaults={'req_path': ''})
@app.route('/<path:req_path>')
@login_required
def files_view(req_path):
    base_dir = app.config['DRIVE_ROOT']
    abs_path = os.path.join(base_dir, req_path)
    if not os.path.abspath(abs_path).startswith(base_dir): return "Invalid Path", 400
    if abs_path.startswith(TEMP_DIR): return "Access Denied", 403

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
                if l.endswith(('.png','.jpg','.jpeg')): ftype = 'image'
                elif l.endswith(('.mp4','.webm')): ftype = 'video'
            file_list.append({'name': item, 'is_dir': is_dir, 'type': ftype, 'size': '-' if is_dir else format_bytes(os.path.getsize(full))})
        file_list.sort(key=lambda x: (not x['is_dir'], x['name'].lower()))
        return render_template('files.html', items=file_list, current_path=req_path, used=used_h, total=total_h, percent=percent)
    elif os.path.exists(abs_path):
        return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path))
    return "Not Found", 404

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
    file = request.files['file']
    filename = request.form['filename']
    path = request.form['path']
    total_size = int(request.form['totalSize'])
    identifier = secure_filename(f"{path}_{filename}_{total_size}")
    temp_file = os.path.join(TEMP_DIR, identifier)
    with open(temp_file, 'ab') as f: f.write(file.read())
    if os.path.getsize(temp_file) >= total_size:
        dest_path = os.path.join(app.config['DRIVE_ROOT'], path, secure_filename(filename))
        base, ext = os.path.splitext(dest_path)
        counter = 1
        while os.path.exists(dest_path):
            dest_path = f"{base}_{counter}{ext}"; counter += 1
        shutil.move(temp_file, dest_path)
        return jsonify({'status': 'done'})
    return jsonify({'status': 'chunk_saved'})

@app.route('/api/operate', methods=['POST'])
@login_required
def api_operate():
    data = request.get_json(); action = data.get('action'); path = data.get('path')
    target = os.path.join(app.config['DRIVE_ROOT'], path)
    if not os.path.abspath(target).startswith(app.config['DRIVE_ROOT']): return jsonify({'ok': False}), 403
    try:
        if action == 'mkdir': os.makedirs(os.path.join(target, data.get('name')), exist_ok=False)
        elif action == 'delete': shutil.rmtree(target) if os.path.isdir(target) else os.remove(target)
        elif action == 'share':
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
        if not req_path: return "Expired", 404
        abs_path = os.path.join(app.config['DRIVE_ROOT'], req_path)
        return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path), as_attachment=True)
    except: return "Error", 500
EOF

# --- 写入 wsgi.py ---
echo "from app import app" > "${PROJECT_DIR}/wsgi.py"
echo 'if __name__ == "__main__": app.run()' >> "${PROJECT_DIR}/wsgi.py"

# --- 写入前端 templates ---
mkdir -p "${PROJECT_DIR}/templates"
# (Login.html)
cat << 'EOF' > "${PROJECT_DIR}/templates/login.html"
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@1/css/pico.min.css"><title>Login</title><style>body{display:flex;justify-content:center;align-items:center;height:100vh;background:#f0f2f5}article{min-width:320px}</style></head><body><article><h3>Cloud Drive</h3><form method="post"><input type="text" name="username" placeholder="User" required><input type="password" name="password" placeholder="Pass" required><button type="submit">Login</button></form></article></body></html>
EOF
# (Files.html - 包含断点续传逻辑)
cat << 'EOF' > "${PROJECT_DIR}/templates/files.html"
<!doctype html><html lang="zh" data-theme="light"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@1/css/pico.min.css"><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><title>My Cloud</title><style>:root{--primary:#1095c1}body{background-color:#f8f9fa}.container{max-width:1000px;margin-top:2rem}.file-list{background:#fff;border-radius:8px;box-shadow:0 2px 6px rgba(0,0,0,0.05);list-style:none;padding:0}.file-item{display:flex;align-items:center;padding:12px 20px;border-bottom:1px solid #eee}.file-item:hover{background-color:#f1f8ff}.file-name{flex-grow:1;margin-left:10px;text-decoration:none;color:#333;cursor:pointer}.actions i{margin-left:10px;cursor:pointer;color:#666}.actions i:hover{color:var(--primary)}#drop-zone{border:2px dashed #ccc;border-radius:10px;padding:20px;text-align:center;margin-bottom:1rem;background:#fff;transition:.3s}#drop-zone.dragover{border-color:var(--primary);background:#eefbff}#upload-status{display:none;margin-bottom:1rem;padding:1rem;background:#fff;border:1px solid #ddd}.progress-fill{height:5px;background:var(--primary);width:0%}</style></head><body>
<nav class="container-fluid" style="background:#fff;padding:0.5rem 2rem;box-shadow:0 1px 3px rgba(0,0,0,0.1)"><ul><li><strong>☁️ Cloud (Caddy)</strong></li></ul><ul><li><small>{{used}}/{{total}}</small></li><li><a href="{{url_for('logout')}}" class="secondary outline">Exit</a></li></ul></nav>
<main class="container"><div style="display:flex;justify-content:space-between;margin-bottom:1rem"><nav aria-label="breadcrumb"><ul><li><a href="{{url_for('files_view',req_path='')}}">Root</a></li>{% if current_path %}<li>...{{current_path.split('/')[-1]}}</li>{% endif %}</ul></nav><div role="group"><button class="outline" onclick="document.getElementById('file-input').click()"><i class="fa-solid fa-cloud-arrow-up"></i> Upload</button><button class="outline" onclick="promptNewFolder()"><i class="fa-solid fa-folder-plus"></i> New</button></div></div>
<div id="drop-zone"><i class="fa-solid fa-file-import" style="font-size:2rem"></i><br>Drag & Drop<input type="file" id="file-input" multiple style="display:none"></div>
<div id="upload-status"><div>Uploading: <span id="u-name"></span></div><div style="background:#eee;height:5px;margin-top:5px"><div class="progress-fill" id="u-fill"></div></div><small id="u-msg"></small></div>
<ul class="file-list">{% if current_path %}<li class="file-item" onclick="location.href='{{url_for('files_view',req_path=current_path.rsplit('/',1)[0] if '/' in current_path else '')}}'"><i class="fa-solid fa-reply"></i><span class="file-name">Back</span></li>{% endif %}{% for item in items %}<li class="file-item">{% if item.is_dir %}<i class="fa-solid fa-folder" style="color:#ffd43b"></i><a class="file-name" href="{{url_for('files_view',req_path=(current_path+'/'+item.name)if current_path else item.name)}}">{{item.name}}</a>{% else %}<i class="fa-solid fa-file" style="color:#868e96"></i><span class="file-name" onclick="preview('{{item.type}}','{{url_for('preview_file',req_path=(current_path+'/'+item.name)if current_path else item.name)}}')">{{item.name}}</span>{% endif %}<small>{{item.size}}</small><div class="actions">{% if not item.is_dir %}<i class="fa-solid fa-share-nodes" onclick="shareItem('{{(current_path+'/'+item.name)if current_path else item.name}}')"></i><i class="fa-solid fa-download" onclick="window.location.href='{{url_for('preview_file',req_path=(current_path+'/'+item.name)if current_path else item.name)}}'"></i>{% endif %}<i class="fa-solid fa-trash" onclick="deleteItem('{{(current_path+'/'+item.name)if current_path else item.name}}')"></i></div></li>{% else %}<li class="file-item" style="justify-content:center;color:#999">Empty</li>{% endfor %}</ul></main>
<script>
const CHUNK=5*1024*1024;let isUp=false;
document.getElementById('file-input').addEventListener('change',e=>hFiles(e.target.files));
const dz=document.getElementById('drop-zone');dz.addEventListener('dragover',e=>{e.preventDefault();dz.classList.add('dragover')});dz.addEventListener('drop',e=>{e.preventDefault();dz.classList.remove('dragover');hFiles(e.dataTransfer.files)});
async function hFiles(fs){if(isUp)return alert("Wait");if(!fs.length)return;isUp=true;document.getElementById('upload-status').style.display='block';for(let f of fs)await upOne(f);isUp=false;alert("Done");location.reload()}
async function upOne(f){
 document.getElementById('u-name').innerText=f.name;let uped=0;
 try{let r=await fetch('{{url_for("upload_check")}}',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({filename:f.name,totalSize:f.size,path:'{{current_path}}'})});let d=await r.json();uped=d.uploaded}catch(e){}
 if(uped>=f.size){document.getElementById('u-fill').style.width='100%';return}
 while(uped<f.size){
  let chunk=f.slice(uped,uped+CHUNK),fd=new FormData();fd.append('file',chunk);fd.append('filename',f.name);fd.append('path','{{current_path}}');fd.append('totalSize',f.size);
  try{document.getElementById('u-msg').innerText="Sending...";let res=await fetch('{{url_for("upload_chunk")}}',{method:'POST',body:fd});let r=await res.json();if(r.status==='chunk_saved'||r.status==='done'){uped+=chunk.size;document.getElementById('u-fill').style.width=Math.min((uped/f.size)*100,100)+'%'}else throw 1}catch(e){document.getElementById('u-msg').innerText="Retrying...";await new Promise(r=>setTimeout(r,3000))}
 }
}
function pApi(a,d){return fetch("{{url_for('api_operate')}}",{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:a,...d})}).then(r=>r.json())}
function promptNewFolder(){let n=prompt("Name:");if(n)pApi('mkdir',{path:'{{current_path}}',name:n}).then(r=>r.ok?location.reload():alert(r.msg))}
function deleteItem(p){if(confirm("Delete?"))pApi('delete',{path:p}).then(r=>r.ok?location.reload():alert(r.msg))}
function shareItem(p){pApi('share',{path:p}).then(r=>r.ok?prompt("Link:",r.link):alert(r.msg))}
function preview(t,u){if(t==='image'||t==='video')window.open(u);else location.href=u}
</script></body></html>
EOF
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$PROJECT_DIR"

# --- 5. 配置 Gunicorn ---
cat << EOF > /etc/systemd/system/my_cloud_drive.service
[Unit]
Description=Gunicorn
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
systemctl daemon-reload
systemctl enable my_cloud_drive
systemctl restart my_cloud_drive

# --- 6. 配置 Caddy ---
echo -e "\n\033[0;33m>>> 生成 Caddyfile 配置...\033[0m"

# 注意：Caddyfile 语法非常简洁
# 1. request_body: 允许大文件上传 (虽然V4.0切片了，但设置大点无妨)
# 2. reverse_proxy: 指向 Gunicorn 的 sock 文件
cat << EOF > /etc/caddy/Caddyfile
${DOMAIN_OR_IP} {
    # 限制上传大小 (Caddy 默认也是有限制的，这里放宽)
    request_body {
        max_size 10GB
    }

    # 启用 Gzip 压缩
    encode gzip

    # 反向代理到 Unix Socket
    reverse_proxy unix/${PROJECT_DIR}/my_cloud_drive.sock {
        # 设置传输超时，防止大文件处理时断开
        transport http {
            response_header_timeout 300s
        }
    }
}
EOF

# --- 7. 启动 ---
echo -e "\n\033[0;33m>>> 重启 Caddy...\033[0m"
systemctl enable caddy
systemctl restart caddy

echo -e "\n\033[0;32m=============================================\033[0m"
echo -e "  Caddy 版部署完成！"
echo -e "  访问地址: https://${DOMAIN_OR_IP} (如果是 IP 则是 http)"
echo -e "\033[0;32m=============================================\033[0m"

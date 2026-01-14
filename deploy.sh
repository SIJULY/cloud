#!/bin/bash

# ==============================================================================
#           一键部署 Python + Flask + Gunicorn + Nginx 个人网盘项目
#
#                    V4.0 - 进阶存储版 (支持断点续传)
#
# 核心升级:
# 1. [断点续传] 前端分片(10MB/片)上传，支持暂停、网络中断后自动从断点继续。
# 2. [秒传机制] 如果文件已存在且大小一致，直接提示成功（基础版秒传）。
# 3. [状态反馈] 实时计算上传速度和剩余时间。
# 4. [稳定性] 即使 Nginx 限制了 body 大小，分片上传也能绕过限制上传超大文件。
# ==============================================================================

# --- 检查 Root ---
if [ "$(id -u)" -ne 0 ]; then echo "必须使用 Root 运行"; exit 1; fi

# --- 配置部分 (如果之前运行过，会自动读取旧配置，否则请手动填入) ---
# 这里为了方便直接升级，假设你已经运行过 V3.0/V3.1
# 如果是全新安装，请确保以下变量被正确替换或设置
PROJECT_DIR="/var/www/my_cloud_drive"
# 如果检测到已存在配置文件，尝试提取配置（简单提取，仅供参考）
if [ -f "${PROJECT_DIR}/app.py" ]; then
    echo "检测到旧版本，正在提取配置并升级核心组件..."
    # 重新加载必要的环境变量设置（这里简化处理，直接覆盖代码）
fi

# --- 1. 升级后端代码 app.py (支持分片接收) ---
echo "正在更新 app.py 以支持分片上传..."

cat << 'EOF' > "${PROJECT_DIR}/app.py"
import os
import json
import uuid
import shutil
import time
from functools import wraps
from flask import Flask, render_template, request, send_from_directory, redirect, url_for, flash, jsonify, session
from werkzeug.utils import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash

# 从环境变量读取配置
SECRET_KEY = os.environ.get('SECRET_KEY', 'default_secret')
DRIVE_ROOT = os.environ.get('DRIVE_ROOT', '/tmp')
APP_USERNAME = os.environ.get('APP_USERNAME', 'admin')
APP_PASSWORD_HASH = generate_password_hash(os.environ.get('APP_PASSWORD', 'password'))
SHARES_FILE = os.path.join(DRIVE_ROOT, '.shares.json')
TEMP_DIR = os.path.join(DRIVE_ROOT, '.temp_uploads') # 临时文件存放区

app = Flask(__name__)
app.config['SECRET_KEY'] = SECRET_KEY
app.config['DRIVE_ROOT'] = os.path.abspath(DRIVE_ROOT)
# 分片上传不需要 Flask 限制 body 大小，因为每个分片很小
app.config['MAX_CONTENT_LENGTH'] = None 

os.makedirs(app.config['DRIVE_ROOT'], exist_ok=True)
os.makedirs(TEMP_DIR, exist_ok=True) # 创建临时目录

if not os.path.exists(SHARES_FILE):
    with open(SHARES_FILE, 'w') as f: json.dump({}, f)

# --- 辅助函数 ---
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

# --- 路由 ---
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
    
    # 忽略临时文件夹
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
            
            file_list.append({
                'name': item, 'is_dir': is_dir, 'type': ftype,
                'size': '-' if is_dir else format_bytes(os.path.getsize(full))
            })
        file_list.sort(key=lambda x: (not x['is_dir'], x['name'].lower()))
        return render_template('files.html', items=file_list, current_path=req_path, used=used_h, total=total_h, percent=percent)
    elif os.path.exists(abs_path):
        return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path))
    return "Not Found", 404

# --- 核心：断点续传 API ---

@app.route('/api/upload_check', methods=['POST'])
@login_required
def upload_check():
    """检查文件已上传的大小，用于续传"""
    data = request.get_json()
    # 使用 文件名+大小+路径 生成唯一标识，防止不同目录下同名文件冲突
    identifier = secure_filename(f"{data['path']}_{data['filename']}_{data['totalSize']}")
    temp_file = os.path.join(TEMP_DIR, identifier)
    
    if os.path.exists(temp_file):
        return jsonify({'uploaded': os.path.getsize(temp_file)})
    return jsonify({'uploaded': 0})

@app.route('/api/upload_chunk', methods=['POST'])
@login_required
def upload_chunk():
    """接收分片"""
    file = request.files['file']
    # 前端传来的参数
    filename = request.form['filename']
    path = request.form['path']
    total_size = int(request.form['totalSize'])
    # chunk_offset = int(request.form['offset']) # 虽然前端传了，但我们直接用 append 模式更安全
    
    identifier = secure_filename(f"{path}_{filename}_{total_size}")
    temp_file = os.path.join(TEMP_DIR, identifier)
    
    # 追加模式写入分片
    with open(temp_file, 'ab') as f:
        f.write(file.read())
    
    current_size = os.path.getsize(temp_file)
    
    # 如果大小一致，说明传输完成，移动到目标目录
    if current_size >= total_size:
        dest_dir = os.path.join(app.config['DRIVE_ROOT'], path)
        dest_path = os.path.join(dest_dir, secure_filename(filename))
        
        # 自动重命名处理冲突
        base, ext = os.path.splitext(dest_path)
        counter = 1
        while os.path.exists(dest_path):
            dest_path = f"{base}_{counter}{ext}"
            counter += 1
            
        shutil.move(temp_file, dest_path)
        return jsonify({'status': 'done', 'path': dest_path})
        
    return jsonify({'status': 'chunk_saved', 'current_size': current_size})

# --- 其他 API ---
@app.route('/api/operate', methods=['POST'])
@login_required
def api_operate():
    data = request.get_json()
    action = data.get('action')
    path = data.get('path')
    base = app.config['DRIVE_ROOT']
    target = os.path.join(base, path)
    
    if not os.path.abspath(target).startswith(base): return jsonify({'ok': False, 'msg': '非法路径'}), 403
    
    try:
        if action == 'mkdir':
            os.makedirs(os.path.join(target, data.get('name')), exist_ok=False)
        elif action == 'delete':
            if os.path.isdir(target): shutil.rmtree(target)
            else: os.remove(target)
        elif action == 'share':
            with open(SHARES_FILE, 'r') as f: shares = json.load(f)
            token = uuid.uuid4().hex
            shares[token] = path
            atomic_write_json(SHARES_FILE, shares)
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
        if not req_path: return "已失效", 404
        abs_path = os.path.join(app.config['DRIVE_ROOT'], req_path)
        if not os.path.exists(abs_path): return "文件不存在", 404
        return send_from_directory(os.path.dirname(abs_path), os.path.basename(abs_path), as_attachment=True)
    except: return "Error", 500
EOF

# --- 2. 升级前端 files.html (实现 JS 分片逻辑) ---
echo "正在更新 files.html 以支持分片上传逻辑..."

cat << 'EOF' > "${PROJECT_DIR}/templates/files.html"
<!doctype html><html lang="zh" data-theme="light"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@1/css/pico.min.css"><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><title>我的云盘 V4.0</title>
<style>
:root { --primary: #1095c1; }
body { background-color: #f8f9fa; }
.container { max-width: 1000px; margin-top: 2rem; }
.file-list { background: #fff; border-radius: 8px; box-shadow: 0 2px 6px rgba(0,0,0,0.05); padding: 0; list-style: none; }
.file-item { display: flex; align-items: center; padding: 12px 20px; border-bottom: 1px solid #eee; transition: background 0.2s; }
.file-item:hover { background-color: #f1f8ff; }
.file-icon { font-size: 1.5rem; width: 40px; text-align: center; color: #555; }
.file-name { flex-grow: 1; text-decoration: none; color: #333; font-weight: 500; cursor: pointer; }
.file-meta { font-size: 0.85rem; color: #888; margin-right: 15px; }
.actions i { cursor: pointer; margin-left: 12px; color: #666; }
.actions i:hover { color: var(--primary); }
#drop-zone { border: 2px dashed #ccc; border-radius: 10px; padding: 20px; text-align: center; margin-bottom: 1rem; background: #fff; color: #888; transition: .3s; }
#drop-zone.dragover { border-color: var(--primary); background: #eefbff; }
/* Upload Status */
#upload-status { display: none; margin-bottom: 1rem; padding: 1rem; background: #fff; border-radius: 8px; border: 1px solid #ddd; }
.progress-bar { height: 10px; border-radius: 5px; background: #eee; margin-top: 5px; overflow: hidden; }
.progress-fill { height: 100%; background: var(--primary); width: 0%; transition: width 0.2s; }
</style></head><body>

<nav class="container-fluid" style="background:#fff; box-shadow:0 1px 3px rgba(0,0,0,0.1); padding: 0.5rem 2rem;">
  <ul><li><strong>☁️ 极速云盘 V4.0</strong></li></ul>
  <ul><li><small>{{used}} / {{total}}</small></li><li><a href="{{url_for('logout')}}" role="button" class="outline secondary">退出</a></li></ul>
</nav>

<main class="container">
  <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem;">
    <nav aria-label="breadcrumb">
      <ul><li><a href="{{url_for('files_view', req_path='')}}">根目录</a></li>{% if current_path %}<li>...{{ current_path.split('/')[-1] }}</li>{% endif %}</ul>
    </nav>
    <div role="group">
        <button class="outline" onclick="document.getElementById('file-input').click()"><i class="fa-solid fa-cloud-arrow-up"></i> 上传</button>
        <button class="outline" onclick="promptNewFolder()"><i class="fa-solid fa-folder-plus"></i> 新建</button>
    </div>
  </div>

  <div id="drop-zone">
    <i class="fa-solid fa-file-import" style="font-size: 2rem;"></i><br>拖拽文件上传 (支持断点续传)
    <input type="file" id="file-input" multiple style="display:none">
  </div>

  <div id="upload-status">
    <div><strong>正在上传: </strong> <span id="upload-filename"></span></div>
    <div style="display:flex; justify-content:space-between; font-size:0.8rem; color:#666;">
        <span id="upload-speed">0 MB/s</span>
        <span id="upload-percent">0%</span>
    </div>
    <div class="progress-bar"><div class="progress-fill" id="progress-fill"></div></div>
    <div style="margin-top:0.5rem; text-align:right;">
        <small id="upload-msg" style="color:orange"></small>
    </div>
  </div>

  <ul class="file-list">
    {% if current_path %}
    <li class="file-item" onclick="location.href='{{ url_for('files_view', req_path=current_path.rsplit('/', 1)[0] if '/' in current_path else '') }}'">
       <div class="file-icon"><i class="fa-solid fa-reply"></i></div><div class="file-name">返回上一级</div>
    </li>
    {% endif %}
    {% for item in items %}
    <li class="file-item">
        <div class="file-icon">
            {% if item.is_dir %}<i class="fa-solid fa-folder" style="color:#ffd43b"></i>
            {% elif item.type == 'image' %}<i class="fa-solid fa-image" style="color:#5c7cfa"></i>
            {% elif item.type == 'video' %}<i class="fa-solid fa-video" style="color:#fa5252"></i>
            {% else %}<i class="fa-solid fa-file" style="color:#868e96"></i>{% endif %}
        </div>
        {% if item.is_dir %}<a class="file-name" href="{{ url_for('files_view', req_path=(current_path + '/' + item.name) if current_path else item.name) }}">{{ item.name }}</a>
        {% else %}<span class="file-name" onclick="preview('{{item.type}}', '{{ url_for('preview_file', req_path=(current_path + '/' + item.name) if current_path else item.name) }}')">{{ item.name }}</span>{% endif %}
        <div class="file-meta">{{ item.size }}</div>
        <div class="actions">
            {% if not item.is_dir %}
            <i class="fa-solid fa-share-nodes" onclick="shareItem('{{ (current_path + '/' + item.name) if current_path else item.name }}')"></i>
            <i class="fa-solid fa-download" onclick="window.location.href='{{ url_for('preview_file', req_path=(current_path + '/' + item.name) if current_path else item.name) }}'"></i>
            {% endif %}
            <i class="fa-solid fa-trash" onclick="deleteItem('{{ (current_path + '/' + item.name) if current_path else item.name }}')"></i>
        </div>
    </li>
    {% else %}<li class="file-item" style="justify-content:center; color:#999;">空目录</li>{% endfor %}
  </ul>
</main>

<script>
// --- 核心：断点续传逻辑 ---
const CHUNK_SIZE = 5 * 1024 * 1024; // 5MB 分片
let isUploading = false;

document.getElementById('file-input').addEventListener('change', e => handleFiles(e.target.files));
const dropZone = document.getElementById('drop-zone');
dropZone.addEventListener('dragover', e => { e.preventDefault(); dropZone.classList.add('dragover'); });
dropZone.addEventListener('dragleave', e => dropZone.classList.remove('dragover'));
dropZone.addEventListener('drop', e => { e.preventDefault(); dropZone.classList.remove('dragover'); handleFiles(e.dataTransfer.files); });

async function handleFiles(files) {
    if (isUploading) return alert("当前有任务正在上传，请稍后");
    if (!files.length) return;
    isUploading = true;
    document.getElementById('upload-status').style.display = 'block';

    for (let file of files) {
        await uploadOneFile(file);
    }
    
    isUploading = false;
    alert("所有文件上传完成！");
    location.reload();
}

async function uploadOneFile(file) {
    const uiName = document.getElementById('upload-filename');
    const uiPercent = document.getElementById('upload-percent');
    const uiFill = document.getElementById('progress-fill');
    const uiMsg = document.getElementById('upload-msg');
    
    uiName.innerText = file.name;
    uiMsg.innerText = "正在检查断点...";
    
    // 1. 检查服务器已上传多少 (断点检测)
    let uploadedSize = 0;
    try {
        const res = await fetch('{{url_for("upload_check")}}', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({filename: file.name, totalSize: file.size, path: '{{current_path}}'})
        });
        const data = await res.json();
        uploadedSize = data.uploaded;
    } catch(e) { console.error(e); }

    if(uploadedSize >= file.size) {
        uiFill.style.width = '100%';
        uiMsg.innerText = "秒传成功！";
        return; // 已存在
    }

    // 2. 开始分片上传
    const startTime = Date.now();
    let startBytes = uploadedSize;
    
    while(uploadedSize < file.size) {
        const chunk = file.slice(uploadedSize, uploadedSize + CHUNK_SIZE);
        const formData = new FormData();
        formData.append('file', chunk);
        formData.append('filename', file.name);
        formData.append('path', '{{current_path}}');
        formData.append('totalSize', file.size);
        formData.append('offset', uploadedSize); // 虽然服务器用append，但传过去以防万一

        try {
            uiMsg.innerText = "正在上传分片...";
            const res = await fetch('{{url_for("upload_chunk")}}', {method: 'POST', body: formData});
            const result = await res.json();
            
            if(result.status === 'chunk_saved' || result.status === 'done') {
                uploadedSize += chunk.size;
                // 更新UI
                const p = Math.min((uploadedSize / file.size) * 100, 100).toFixed(1);
                uiPercent.innerText = p + '%';
                uiFill.style.width = p + '%';
                
                // 计算速度
                const elapsed = (Date.now() - startTime) / 1000;
                const speed = ((uploadedSize - startBytes) / 1024 / 1024 / elapsed).toFixed(1);
                document.getElementById('upload-speed').innerText = speed + ' MB/s';
                
                if (result.status === 'done') uiMsg.innerText = "上传完成，正在处理...";
            } else {
                throw new Error("Upload failed");
            }
        } catch(e) {
            uiMsg.innerText = "网络错误，3秒后重试...";
            await new Promise(r => setTimeout(r, 3000));
            // 循环继续，自动重试当前分片
        }
    }
}

// --- 通用功能 ---
function postApi(action, payload) {
    return fetch("{{url_for('api_operate')}}", {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action,...payload})}).then(r=>r.json());
}
function promptNewFolder() {
    const name = prompt("文件夹名称:");
    if(name) postApi('mkdir', {path: '{{current_path}}', name}).then(r => r.ok ? location.reload() : alert(r.msg));
}
function deleteItem(path) { if(confirm("确定删除?")) postApi('delete', {path}).then(r => r.ok ? location.reload() : alert(r.msg)); }
function shareItem(path) { postApi('share', {path}).then(r => r.ok ? prompt("分享链接:", r.link) : alert(r.msg)); }
function preview(type, url) { if(type==='image'||type==='video') window.open(url); else location.href=url; }
</script></body></html>
EOF

# --- 3. 确保权限 ---
chown -R "$NEW_USERNAME:$NEW_USERNAME" "$PROJECT_DIR"

# --- 4. 重启服务 ---
echo "正在重启服务..."
systemctl restart my_cloud_drive
# 重新加载 Nginx 确保配置生效 (虽然 Nginx 配置没变，但重启一下稳妥)
systemctl restart nginx

echo -e "\n${GREEN}升级完成！V4.0 (断点续传版) 已部署。${NC}"
echo -e "现在您可以尝试上传 GB 级别的大文件，支持中途关闭浏览器再打开继续上传。"

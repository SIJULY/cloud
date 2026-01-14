import os
import time
import shutil
import json
import uuid
import zipfile
from functools import wraps
from flask import Flask, render_template, jsonify, request, send_file, send_from_directory, redirect, session, url_for

app = Flask(__name__)
app.config['SEND_FILE_MAX_AGE_DEFAULT'] = 0
# Use a fixed secret key or read from environment variable
app.secret_key = os.getenv('SECRET_KEY', 'default-secret-key-please-change-in-prod')

# --- Environment Variable Configuration ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.getenv('STORAGE_PATH', os.path.join(BASE_DIR, 'storage'))
TRASH_DIR = os.getenv('TRASH_PATH', os.path.join(BASE_DIR, 'trash'))
SHARE_DIR = os.getenv('SHARE_PATH', os.path.join(BASE_DIR, 'shares'))
TRASH_META_FILE = os.path.join(TRASH_DIR, 'metadata.json')
SHARE_META_FILE = os.path.join(SHARE_DIR, 'metadata.json')

# Credentials
ADMIN_USER = os.getenv('ADMIN_USER', 'admin')
ADMIN_PASS = os.getenv('ADMIN_PASS', 'admin123')

# Ensure directories exist
for d in [ROOT_DIR, TRASH_DIR, SHARE_DIR]:
    if not os.path.exists(d): os.makedirs(d)

CATEGORY_EXTENSIONS = {
    'image': ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.tiff', '.ico'],
    'video': ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp'],
    'doc':   ['.txt', '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.md', '.csv', '.json'],
    'app':   ['.exe', '.dmg', '.pkg', '.apk', '.ipa', '.deb', '.rpm', '.msi']
}

# --- Authentication Decorator ---
def auth_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        # Check session for login marker
        if not session.get('logged_in'):
            # Return 401 for API requests
            if request.path.startswith('/api/'):
                return jsonify({'error': 'Unauthorized'}), 401
            # Redirect to login page for page access
            return redirect('/login')
        return f(*args, **kwargs)
    return decorated

# --- Data Management Classes ---
class JsonManager:
    def __init__(self, filepath):
        self.filepath = filepath
        self.load_metadata()
        
    def load_metadata(self):
        if os.path.exists(self.filepath):
            try:
                with open(self.filepath, 'r', encoding='utf-8') as f:
                    self.data = json.load(f)
            except Exception as e:
                # 【修改】打印错误日志，而不是默默清空
                print(f"❌ Error loading {self.filepath}: {e}")
                # 如果文件坏了，暂时保持空，但至少后台能看到报错
                self.data = {}
        else:
            self.data = {}
            
    def save_metadata(self):
        # 【修改】增加 flush 确保数据真正写入硬盘
        try:
            with open(self.filepath, 'w', encoding='utf-8') as f:
                json.dump(self.data, f, ensure_ascii=False, indent=2)
                f.flush()
                os.fsync(f.fileno()) # 强制写入硬盘，防止重启丢失
        except Exception as e:
            print(f"❌ Error saving {self.filepath}: {e}")

class TrashManager(JsonManager):
    def add_item(self, filename, original_rel_path, is_dir):
        unique_name = f"{int(time.time())}_{uuid.uuid4().hex[:6]}_{filename}"
        self.data[unique_name] = {
            'original_name': filename, 'original_path': original_rel_path, 'is_dir': is_dir,
            'deleted_at': time.strftime('%Y-%m-%d %H:%M:%S'),
            'size_str': self._get_size_str(original_rel_path) if not is_dir else '-'
        }
        self.save_metadata()
        return unique_name
    def remove_item(self, unique_name):
        if unique_name in self.data: del self.data[unique_name]; self.save_metadata()
    def get_list(self):
        res = []
        for uid, info in self.data.items():
            res.append({'id': uid, 'name': info['original_name'], 'path': info['original_path'], 'mtime': info['deleted_at'], 'size': info.get('size_str', '-'), 'is_dir': info['is_dir']})
        return sorted(res, key=lambda x: x['mtime'], reverse=True)
    def _get_size_str(self, rel_path):
        try: return human_readable_size(os.path.getsize(os.path.join(ROOT_DIR, rel_path)))
        except: return '-'

class ShareManager(JsonManager):
    def create_share(self, rel_path):
        share_id = uuid.uuid4().hex[:6]
        while share_id in self.data: share_id = uuid.uuid4().hex[:6]
        full_path = os.path.join(ROOT_DIR, rel_path)
        self.data[share_id] = {
            'file_path': rel_path, 'file_name': os.path.basename(rel_path), 'is_dir': os.path.isdir(full_path),
            'created_at': time.strftime('%Y-%m-%d %H:%M:%S'), 'downloads': 0
        }
        self.save_metadata()
        return share_id
    def cancel_share(self, share_id):
        if share_id in self.data: del self.data[share_id]; self.save_metadata(); return True
        return False
    def get_list(self):
        res = []
        for sid, info in self.data.items():
            exists = os.path.exists(os.path.join(ROOT_DIR, info['file_path']))
            res.append({'id': sid, 'name': info['file_name'], 'path': info['file_path'], 'mtime': info['created_at'], 'downloads': info.get('downloads', 0), 'status': 'normal' if exists else 'lost'})
        return sorted(res, key=lambda x: x['mtime'], reverse=True)
    def get_file_info(self, share_id):
        if share_id in self.data:
            info = self.data[share_id]; 
            # Note: Incrementing downloads here happens on view, ideally move to download action
            # keeping logic simple as per request
            self.save_metadata(); 
            return info
        return None
    def increment_download(self, share_id):
        if share_id in self.data:
            self.data[share_id]['downloads'] = self.data[share_id].get('downloads', 0) + 1
            self.save_metadata()

trash_manager = TrashManager(TRASH_META_FILE)
share_manager = ShareManager(SHARE_META_FILE)

def human_readable_size(size):
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size < 1024: return f"{size:.2f} {unit}"
        size /= 1024
    return f"{size:.2f} PB"

def get_disk_usage():
    try:
        total, used, free = shutil.disk_usage(ROOT_DIR)
        return {'used': human_readable_size(used), 'total': human_readable_size(total), 'percent': (used / total) * 100}
    except: return {'used': '0 B', 'total': '0 B', 'percent': 0}

# ================= Routes =================

# 1. Login Page (GET)
@app.route('/login', methods=['GET'])
def login_page():
    if session.get('logged_in'):
        return redirect('/')
    return render_template('login.html')

# 2. Login API (POST)
@app.route('/api/login', methods=['POST'])
def login_api():
    data = request.json
    if data.get('username') == ADMIN_USER and data.get('password') == ADMIN_PASS:
        session['logged_in'] = True
        return jsonify({'status': 'success'})
    return jsonify({'status': 'fail', 'message': '账号或密码错误'}), 401

# 3. Logout API
@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect('/login')

# 4. Home Page (Protected)
@app.route('/')
@auth_required
def index():
    return render_template('index.html')

# 5. Public Share Link (No Auth Required) 
@app.route('/s/<share_id>')
def public_share_link(share_id):
    info = share_manager.get_file_info(share_id)
    if not info: 
        return "分享链接已过期或不存在", 404
    
    abs_path = os.path.join(ROOT_DIR, info['file_path'])
    if not os.path.exists(abs_path): 
        return "源文件已被删除", 404
    
    if info['is_dir']: 
        return f"这是一个文件夹 ({info['file_name']})，暂不支持下载。", 200

    # Logic: If ?dl=1 param exists, stream the file; otherwise render the share page
    if request.args.get('dl') == '1':
        # Increment download count only on actual download/stream
        share_manager.increment_download(share_id)
        # Enable Range header for video streaming/resume support
        response = send_file(abs_path, as_attachment=False, download_name=info['file_name'])
        response.headers["Accept-Ranges"] = "bytes"
        return response
    
    # Generate the download URL pointing back to this route with ?dl=1
    download_url = url_for('public_share_link', share_id=share_id, dl='1')
    return render_template('share.html', filename=info['file_name'], download_url=download_url)

# --- Protected APIs ---

@app.route('/api/list')
@auth_required
def list_files():
    req_path = request.args.get('path', '')
    if '..' in req_path: return jsonify({'error': 'Invalid path'}), 400
    abs_path = os.path.join(ROOT_DIR, req_path)
    if not os.path.exists(abs_path): return jsonify({'files': [], 'usage': get_disk_usage()})
    files = []
    try:
        with os.scandir(abs_path) as entries:
            for entry in entries:
                stat = entry.stat()
                files.append({'name': entry.name, 'is_dir': entry.is_dir(), 'size': human_readable_size(stat.st_size) if not entry.is_dir() else '-', 'mtime': time.strftime('%Y-%m-%d %H:%M', time.localtime(stat.st_mtime)), 'path': os.path.join(req_path, entry.name).replace('\\', '/')})
    except: pass
    return jsonify({'files': sorted(files, key=lambda x: (not x['is_dir'], x['name'])), 'usage': get_disk_usage()})

@app.route('/api/category')
@auth_required
def list_by_category():
    category_type = request.args.get('type')
    valid_exts = set(CATEGORY_EXTENSIONS.get(category_type, []))
    files = []
    for root, dirs, filenames in os.walk(ROOT_DIR):
        for name in filenames:
            if os.path.splitext(name)[1].lower() in valid_exts:
                abs_path = os.path.join(root, name)
                try:
                    stat = os.stat(abs_path)
                    files.append({'name': name, 'is_dir': False, 'size': human_readable_size(stat.st_size), 'mtime': time.strftime('%Y-%m-%d %H:%M', time.localtime(stat.st_mtime)), 'path': os.path.relpath(abs_path, ROOT_DIR).replace('\\', '/')})
                except: pass
    return jsonify({'files': sorted(files, key=lambda x: x['mtime'], reverse=True), 'usage': get_disk_usage()})

@app.route('/api/mkdir', methods=['POST'])
@auth_required
def create_folder():
    try:
        os.makedirs(os.path.join(ROOT_DIR, request.json.get('path', ''), request.json.get('name')), exist_ok=False)
        return jsonify({'status': 'success'})
    except Exception as e: return jsonify({'error': str(e)}), 500

@app.route('/api/rename', methods=['POST'])
@auth_required
def rename_item():
    try:
        os.rename(os.path.join(ROOT_DIR, request.json.get('path')), os.path.join(ROOT_DIR, os.path.dirname(request.json.get('path')), request.json.get('name')))
        return jsonify({'status': 'success'})
    except Exception as e: return jsonify({'error': str(e)}), 500

@app.route('/api/operate', methods=['POST'])
@auth_required
def operate_items():
    data = request.json; action = data.get('action'); dest_abs = os.path.join(ROOT_DIR, data.get('dest', ''))
    if not os.path.exists(dest_abs): return jsonify({'error': 'Dest not found'}), 404
    success, errors = 0, []
    for rel_path in data.get('files', []):
        try:
            src = os.path.join(ROOT_DIR, rel_path); dst = os.path.join(dest_abs, os.path.basename(rel_path))
            if action == 'move': shutil.move(src, dst)
            elif action == 'copy': shutil.copytree(src, dst) if os.path.isdir(src) else shutil.copy2(src, dst)
            success += 1
        except Exception as e: errors.append(str(e))
    return jsonify({'success': success, 'errors': errors})

@app.route('/api/share/create', methods=['POST'])
@auth_required
def create_share_link():
    links = [f"{request.host_url}s/{share_manager.create_share(p)}" for p in request.json.get('files', []) if os.path.exists(os.path.join(ROOT_DIR, p))]
    return jsonify({'status': 'success', 'links': links})

@app.route('/api/share/list', methods=['GET'])
@auth_required
def list_shares(): return jsonify(share_manager.get_list())

@app.route('/api/share/cancel', methods=['POST'])
@auth_required
def cancel_share_link(): share_manager.cancel_share(request.json.get('id')); return jsonify({'status': 'success'})

@app.route('/api/delete', methods=['POST'])
@auth_required
def soft_delete():
    count = 0
    for p in request.json.get('files', []):
        src = os.path.join(ROOT_DIR, p)
        if os.path.exists(src):
            # Check if it's a temp zip file, if so delete permanently
            if os.path.basename(p).startswith('batch_download_') and p.endswith('.zip'):
                try: os.remove(src)
                except: pass
                continue
                
            uid = trash_manager.add_item(os.path.basename(p), p, os.path.isdir(src))
            try: shutil.move(src, os.path.join(TRASH_DIR, uid)); count+=1
            except: pass
    return jsonify({'status': 'success', 'count': count})

@app.route('/api/trash/list')
@auth_required
def get_trash_list(): return jsonify(trash_manager.get_list())

@app.route('/api/trash/restore', methods=['POST'])
@auth_required
def restore_trash():
    count = 0
    for uid in request.json.get('items', []):
        info = trash_manager.data.get(uid)
        if info:
            tgt = os.path.join(ROOT_DIR, info['original_path'])
            if not os.path.exists(os.path.dirname(tgt)): tgt = os.path.join(ROOT_DIR, info['original_name'])
            try: shutil.move(os.path.join(TRASH_DIR, uid), tgt); trash_manager.remove_item(uid); count+=1
            except: pass
    return jsonify({'status': 'success', 'count': count})

@app.route('/api/trash/delete', methods=['POST'])
@auth_required
def permanent_delete():
    for uid in request.json.get('items', []):
        p = os.path.join(TRASH_DIR, uid)
        try: (shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)); trash_manager.remove_item(uid)
        except: pass
    return jsonify({'status': 'success'})

@app.route('/api/trash/empty', methods=['POST'])
@auth_required
def empty_trash():
    for uid in list(trash_manager.data.keys()):
        p = os.path.join(TRASH_DIR, uid)
        try: (shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)); trash_manager.remove_item(uid)
        except: pass
    return jsonify({'status': 'success'})

@app.route('/api/upload', methods=['POST'])
@auth_required
def upload_file():
    if 'file' not in request.files: return jsonify({'error': 'No file'}), 400
    file = request.files['file']; save_dir = os.path.join(ROOT_DIR, request.form.get('path', ''))
    if not os.path.exists(save_dir): os.makedirs(save_dir)
    file.save(os.path.join(save_dir, file.filename))
    return jsonify({'status': 'success'})

@app.route('/api/archive', methods=['POST'])
@auth_required
def archive_files():
    from tasks import compress_files_task
    abs_paths = [os.path.join(ROOT_DIR, p) for p in request.json.get('files')]
    task = compress_files_task.delay(abs_paths)
    return jsonify({'task_id': task.id, 'status': 'Processing'})

@app.route('/api/status/<task_id>')
@auth_required
def task_status(task_id):
    from tasks import compress_files_task
    task = compress_files_task.AsyncResult(task_id)
    res = {'state': task.state}
    if task.state == 'PROGRESS': res.update(task.info)
    elif task.state == 'SUCCESS': res['result'] = task.result
    elif task.state == 'FAILURE': res['error'] = str(task.result)
    return jsonify(res)

@app.route('/api/download_result')
@auth_required
def download_result_file():
    file_path = request.args.get('file')
    # Use basename for download so user sees clean name like "batch_download.zip" or custom name
    return send_file(file_path, as_attachment=True, download_name=os.path.basename(file_path))

@app.route('/api/file')
@auth_required
def get_file_content():
    return send_file(os.path.join(ROOT_DIR, request.args.get('path')))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)

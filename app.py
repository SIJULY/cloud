import os
import time
import shutil
import json
import uuid
from functools import wraps
from flask import Flask, render_template, jsonify, request, send_file, send_from_directory, make_response

app = Flask(__name__)
app.config['SEND_FILE_MAX_AGE_DEFAULT'] = 0

# --- 环境变量配置 (Docker 适配) ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# 优先从环境变量读取路径，默认为本地路径 (方便本地调试)
ROOT_DIR = os.getenv('STORAGE_PATH', os.path.join(BASE_DIR, 'storage'))
TRASH_DIR = os.getenv('TRASH_PATH', os.path.join(BASE_DIR, 'trash'))
SHARE_DIR = os.getenv('SHARE_PATH', os.path.join(BASE_DIR, 'shares'))

# 元数据文件路径
TRASH_META_FILE = os.path.join(TRASH_DIR, 'metadata.json')
SHARE_META_FILE = os.path.join(SHARE_DIR, 'metadata.json')

# 账号密码配置 (从环境变量读取)
ADMIN_USER = os.getenv('ADMIN_USER', 'admin')
ADMIN_PASS = os.getenv('ADMIN_PASS', 'admin123')

# 确保目录存在
for d in [ROOT_DIR, TRASH_DIR, SHARE_DIR]:
    if not os.path.exists(d):
        os.makedirs(d)

# --- 智能分类后缀名配置 ---
CATEGORY_EXTENSIONS = {
    'image': ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.tiff', '.ico'],
    'video': ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp'],
    'doc':   ['.txt', '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.md', '.csv', '.json'],
    'app':   ['.exe', '.dmg', '.pkg', '.apk', '.ipa', '.deb', '.rpm', '.msi']
}

# --- 鉴权装饰器 ---
def auth_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.authorization
        # 如果没有认证信息，或者用户名密码不对
        if not auth or not (auth.username == ADMIN_USER and auth.password == ADMIN_PASS):
            return make_response('需要登录才能访问', 401, {'WWW-Authenticate': 'Basic realm="Login Required"'})
        return f(*args, **kwargs)
    return decorated

# --- 辅助类：数据持久化基类 ---
class JsonManager:
    def __init__(self, filepath):
        self.filepath = filepath
        self.load_metadata()

    def load_metadata(self):
        if os.path.exists(self.filepath):
            try:
                with open(self.filepath, 'r', encoding='utf-8') as f:
                    self.data = json.load(f)
            except:
                self.data = {}
        else:
            self.data = {}

    def save_metadata(self):
        with open(self.filepath, 'w', encoding='utf-8') as f:
            json.dump(self.data, f, ensure_ascii=False, indent=2)

# --- 回收站管理 ---
class TrashManager(JsonManager):
    def add_item(self, filename, original_rel_path, is_dir):
        unique_name = f"{int(time.time())}_{uuid.uuid4().hex[:6]}_{filename}"
        self.data[unique_name] = {
            'original_name': filename,
            'original_path': original_rel_path,
            'is_dir': is_dir,
            'deleted_at': time.strftime('%Y-%m-%d %H:%M:%S'),
            'size_str': self._get_size_str(original_rel_path) if not is_dir else '-'
        }
        self.save_metadata()
        return unique_name

    def remove_item(self, unique_name):
        if unique_name in self.data:
            del self.data[unique_name]
            self.save_metadata()

    def get_list(self):
        res = []
        for uid, info in self.data.items():
            res.append({
                'id': uid,
                'name': info['original_name'],
                'path': info['original_path'],
                'mtime': info['deleted_at'],
                'size': info.get('size_str', '-'),
                'is_dir': info['is_dir']
            })
        return sorted(res, key=lambda x: x['mtime'], reverse=True)
    
    def _get_size_str(self, rel_path):
        try:
            full_path = os.path.join(ROOT_DIR, rel_path)
            size = os.path.getsize(full_path)
            return human_readable_size(size)
        except: return '-'

# --- 分享管理 ---
class ShareManager(JsonManager):
    def create_share(self, rel_path):
        share_id = uuid.uuid4().hex[:6]
        while share_id in self.data:
            share_id = uuid.uuid4().hex[:6]
            
        full_path = os.path.join(ROOT_DIR, rel_path)
        is_dir = os.path.isdir(full_path)
        filename = os.path.basename(rel_path)
        
        self.data[share_id] = {
            'file_path': rel_path,
            'file_name': filename,
            'is_dir': is_dir,
            'created_at': time.strftime('%Y-%m-%d %H:%M:%S'),
            'downloads': 0
        }
        self.save_metadata()
        return share_id

    def cancel_share(self, share_id):
        if share_id in self.data:
            del self.data[share_id]
            self.save_metadata()
            return True
        return False

    def get_list(self):
        res = []
        for sid, info in self.data.items():
            exists = os.path.exists(os.path.join(ROOT_DIR, info['file_path']))
            res.append({
                'id': sid,
                'name': info['file_name'],
                'path': info['file_path'],
                'mtime': info['created_at'],
                'downloads': info.get('downloads', 0),
                'status': 'normal' if exists else 'lost'
            })
        return sorted(res, key=lambda x: x['mtime'], reverse=True)

    def get_file_info(self, share_id):
        if share_id in self.data:
            info = self.data[share_id]
            info['downloads'] = info.get('downloads', 0) + 1
            self.save_metadata()
            return info
        return None

# 初始化管理器
trash_manager = TrashManager(TRASH_META_FILE)
share_manager = ShareManager(SHARE_META_FILE)

# --- 辅助函数 ---
def human_readable_size(size):
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size < 1024:
            return f"{size:.2f} {unit}"
        size /= 1024
    return f"{size:.2f} PB"

def get_disk_usage():
    try:
        total, used, free = shutil.disk_usage(ROOT_DIR)
        usage_percent = (used / total) * 100
        return {'used': human_readable_size(used), 'total': human_readable_size(total), 'percent': usage_percent}
    except:
        return {'used': '0 B', 'total': '0 B', 'percent': 0}

# ================= 路由定义 =================

# 1. 首页 (需要登录)
@app.route('/')
@auth_required
def index():
    return render_template('index.html')

# 2. 公共分享链接 (无需登录!!!)
@app.route('/s/<share_id>')
def public_share_link(share_id):
    info = share_manager.get_file_info(share_id)
    if not info:
        return "分享链接已过期或不存在", 404
    
    abs_path = os.path.join(ROOT_DIR, info['file_path'])
    if not os.path.exists(abs_path):
        return "源文件已被删除，无法下载", 404
    
    if info['is_dir']:
        return f"这是一个文件夹分享 ({info['file_name']})，暂不支持直接下载。", 200
        
    return send_file(abs_path, as_attachment=True, download_name=info['file_name'])

# --- 以下所有 API 都需要登录 ---

@app.route('/api/list')
@auth_required
def list_files():
    req_path = request.args.get('path', '')
    if '..' in req_path: return jsonify({'error': 'Invalid path'}), 400
    
    abs_path = os.path.join(ROOT_DIR, req_path)
    if not os.path.exists(abs_path):
        return jsonify({'files': [], 'usage': get_disk_usage()})

    files = []
    try:
        with os.scandir(abs_path) as entries:
            for entry in entries:
                stat = entry.stat()
                files.append({
                    'name': entry.name,
                    'is_dir': entry.is_dir(),
                    'size': human_readable_size(stat.st_size) if not entry.is_dir() else '-',
                    'mtime': time.strftime('%Y-%m-%d %H:%M', time.localtime(stat.st_mtime)),
                    'path': os.path.join(req_path, entry.name).replace('\\', '/')
                })
    except Exception as e:
        print(f"List error: {e}")

    return jsonify({
        'files': sorted(files, key=lambda x: (not x['is_dir'], x['name'])),
        'usage': get_disk_usage()
    })

@app.route('/api/category')
@auth_required
def list_by_category():
    category_type = request.args.get('type')
    if not category_type or category_type not in CATEGORY_EXTENSIONS:
        return jsonify({'files': [], 'usage': get_disk_usage()})
    
    valid_exts = set(CATEGORY_EXTENSIONS[category_type])
    files = []
    
    for root, dirs, filenames in os.walk(ROOT_DIR):
        for name in filenames:
            ext = os.path.splitext(name)[1].lower()
            if ext in valid_exts:
                abs_path = os.path.join(root, name)
                rel_path = os.path.relpath(abs_path, ROOT_DIR).replace('\\', '/')
                try:
                    stat = os.stat(abs_path)
                    files.append({
                        'name': name,
                        'is_dir': False,
                        'size': human_readable_size(stat.st_size),
                        'mtime': time.strftime('%Y-%m-%d %H:%M', time.localtime(stat.st_mtime)),
                        'path': rel_path
                    })
                except: pass
                
    return jsonify({
        'files': sorted(files, key=lambda x: x['mtime'], reverse=True),
        'usage': get_disk_usage()
    })

@app.route('/api/mkdir', methods=['POST'])
@auth_required
def create_folder():
    data = request.json
    path = data.get('path', '')
    name = data.get('name')
    if not name: return jsonify({'error': 'Name required'}), 400
    target_dir = os.path.join(ROOT_DIR, path, name)
    try:
        os.makedirs(target_dir, exist_ok=False)
        return jsonify({'status': 'success'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/rename', methods=['POST'])
@auth_required
def rename_item():
    data = request.json
    old_path_rel = data.get('path')
    new_name = data.get('name')
    old_abs = os.path.join(ROOT_DIR, old_path_rel)
    parent_dir = os.path.dirname(old_abs)
    new_abs = os.path.join(parent_dir, new_name)
    try:
        os.rename(old_abs, new_abs)
        return jsonify({'status': 'success'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/operate', methods=['POST'])
@auth_required
def operate_items():
    data = request.json
    action = data.get('action')
    files = data.get('files', [])
    dest = data.get('dest', '')
    dest_abs = os.path.join(ROOT_DIR, dest)
    
    if not os.path.exists(dest_abs): return jsonify({'error': 'Destination not found'}), 404
        
    success_count = 0
    errors = []
    for rel_path in files:
        src_abs = os.path.join(ROOT_DIR, rel_path)
        filename = os.path.basename(rel_path)
        target_abs = os.path.join(dest_abs, filename)
        try:
            if action == 'move': shutil.move(src_abs, target_abs)
            elif action == 'copy':
                if os.path.isdir(src_abs): shutil.copytree(src_abs, target_abs)
                else: shutil.copy2(src_abs, target_abs)
            success_count += 1
        except Exception as e: errors.append(str(e))
            
    return jsonify({'success': success_count, 'errors': errors})

# --- 分享 API ---
@app.route('/api/share/create', methods=['POST'])
@auth_required
def create_share_link():
    files = request.json.get('files', [])
    links = []
    for rel_path in files:
        if os.path.exists(os.path.join(ROOT_DIR, rel_path)):
            sid = share_manager.create_share(rel_path)
            # 使用 request.host_url 生成当前域名的链接
            link = f"{request.host_url}s/{sid}"
            links.append(link)
    return jsonify({'status': 'success', 'links': links})

@app.route('/api/share/list', methods=['GET'])
@auth_required
def list_shares():
    return jsonify(share_manager.get_list())

@app.route('/api/share/cancel', methods=['POST'])
@auth_required
def cancel_share_link():
    share_id = request.json.get('id')
    share_manager.cancel_share(share_id)
    return jsonify({'status': 'success'})

# --- 回收站 API ---
@app.route('/api/delete', methods=['POST'])
@auth_required
def soft_delete():
    files = request.json.get('files', [])
    count = 0
    for rel_path in files:
        src_abs = os.path.join(ROOT_DIR, rel_path)
        if not os.path.exists(src_abs): continue
        unique_name = trash_manager.add_item(os.path.basename(rel_path), rel_path, os.path.isdir(src_abs))
        try:
            shutil.move(src_abs, os.path.join(TRASH_DIR, unique_name))
            count += 1
        except: pass
    return jsonify({'status': 'success', 'count': count})

@app.route('/api/trash/list')
@auth_required
def get_trash_list():
    return jsonify(trash_manager.get_list())

@app.route('/api/trash/restore', methods=['POST'])
@auth_required
def restore_trash():
    items = request.json.get('items', [])
    count = 0
    for uid in items:
        info = trash_manager.data.get(uid)
        if not info: continue
        target_abs = os.path.join(ROOT_DIR, info['original_path'])
        if not os.path.exists(os.path.dirname(target_abs)): target_abs = os.path.join(ROOT_DIR, info['original_name'])
        try:
            shutil.move(os.path.join(TRASH_DIR, uid), target_abs)
            trash_manager.remove_item(uid)
            count += 1
        except: pass
    return jsonify({'status': 'success', 'count': count})

@app.route('/api/trash/delete', methods=['POST'])
@auth_required
def permanent_delete():
    items = request.json.get('items', [])
    count = 0
    for uid in items:
        path = os.path.join(TRASH_DIR, uid)
        try:
            if os.path.isdir(path): shutil.rmtree(path)
            else: os.remove(path)
            trash_manager.remove_item(uid)
            count += 1
        except: pass
    return jsonify({'status': 'success', 'count': count})

@app.route('/api/trash/empty', methods=['POST'])
@auth_required
def empty_trash():
    for uid in list(trash_manager.data.keys()):
        path = os.path.join(TRASH_DIR, uid)
        try:
            if os.path.isdir(path): shutil.rmtree(path)
            else: os.remove(path)
        except: pass
        trash_manager.remove_item(uid)
    return jsonify({'status': 'success'})

# --- 上传与下载 ---
@app.route('/api/upload', methods=['POST'])
@auth_required
def upload_file():
    if 'file' not in request.files: return jsonify({'error': 'No file'}), 400
    file = request.files['file']
    rel_path = request.form.get('path', '')
    save_dir = os.path.join(ROOT_DIR, rel_path)
    if not os.path.exists(save_dir): os.makedirs(save_dir)
    file.save(os.path.join(save_dir, file.filename))
    return jsonify({'status': 'success'})

@app.route('/api/archive', methods=['POST'])
@auth_required
def archive_files():
    from tasks import compress_files_task
    data = request.json
    rel_paths = data.get('files')
    abs_paths = [os.path.join(ROOT_DIR, p) for p in rel_paths]
    task = compress_files_task.delay(abs_paths)
    return jsonify({'task_id': task.id, 'status': 'Processing'})

@app.route('/api/status/<task_id>')
@auth_required
def task_status(task_id):
    from tasks import compress_files_task
    task = compress_files_task.AsyncResult(task_id)
    response = {'state': task.state}
    if task.state == 'PROGRESS': response.update(task.info)
    elif task.state == 'SUCCESS': response['result'] = task.result
    elif task.state == 'FAILURE': response['error'] = str(task.result)
    return jsonify(response)

@app.route('/api/download_result')
@auth_required
def download_result_file():
    file_path = request.args.get('file')
    if not file_path or not os.path.exists(file_path): return "File not found", 404
    return send_file(file_path, as_attachment=True)

@app.route('/api/file')
@auth_required
def get_file_content():
    file_path = request.args.get('path')
    abs_path = os.path.join(ROOT_DIR, file_path)
    if not os.path.exists(abs_path): return jsonify({'error': 'Not found'}), 404
    return send_file(abs_path)

if __name__ == '__main__':
    # Docker 容器需要监听 0.0.0.0
    app.run(host='0.0.0.0', port=5000, debug=False)

import os
import time
import zipfile
from celery import Celery

# 从环境变量读取 Redis 配置，默认为 localhost (本地调试用)
# 在 Docker Compose 中，REDIS_URL 会被设置为 redis://redis:6379/0
REDIS_URL = os.getenv('REDIS_URL', 'redis://localhost:6379/0')

celery = Celery('tasks', broker=REDIS_URL, backend=REDIS_URL)

celery.conf.update(
    result_backend=REDIS_URL,
    task_serializer='json',
    accept_content=['json'],
    result_serializer='json',
    timezone='Asia/Shanghai',
    enable_utc=True,
)

@celery.task(bind=True)
def compress_files_task(self, file_paths):
    """
    Celery 异步压缩任务
    """
    if not file_paths:
        return {'status': 'Failed', 'error': 'No files selected'}

    # 压缩文件通常很大，放在 /tmp 或者 storage 根目录下的临时文件夹更安全
    # 这里为了简单，我们把它放在第一个文件的同级目录
    # 注意：在 Docker 中，所有路径必须是容器内的绝对路径
    base_dir = os.path.dirname(file_paths[0])
    zip_filename = f"archive_{int(time.time())}.zip"
    zip_filepath = os.path.join(base_dir, zip_filename)

    total_files = 0
    # 计算文件总数
    for path in file_paths:
        if os.path.isfile(path):
            total_files += 1
        elif os.path.isdir(path):
            for _, _, filenames in os.walk(path):
                total_files += len(filenames)

    processed_count = 0

    try:
        with zipfile.ZipFile(zip_filepath, 'w', zipfile.ZIP_DEFLATED) as zf:
            for path in file_paths:
                if not os.path.exists(path):
                    continue

                if os.path.isfile(path):
                    zf.write(path, arcname=os.path.basename(path))
                    processed_count += 1
                    _update_progress(self, processed_count, total_files, f"正在压缩: {os.path.basename(path)}")
                    
                elif os.path.isdir(path):
                    parent_folder = os.path.dirname(path)
                    for root, dirs, files in os.walk(path):
                        for file in files:
                            abs_path = os.path.join(root, file)
                            rel_path = os.path.relpath(abs_path, parent_folder)
                            zf.write(abs_path, arcname=rel_path)
                            processed_count += 1
                            _update_progress(self, processed_count, total_files, f"正在压缩: {file}")

        return {
            'status': 'Completed',
            'result': zip_filepath,
            'filename': zip_filename,
            'total_files': total_files
        }

    except Exception as e:
        return {'status': 'Failed', 'error': str(e)}


def _update_progress(task_instance, current, total, status_msg):
    if total == 0:
        percent = 0
    else:
        percent = int((current / total) * 100)

    # 稍微限制一下更新频率，防止 Redis 压力过大
    if current % 5 == 0 or current == total:
        task_instance.update_state(
            state='PROGRESS',
            meta={
                'current': current,
                'total': total,
                'percent': percent,
                'status': status_msg
            }
        )

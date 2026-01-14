#!/bin/bash
# 启动 Celery Worker (后台运行)
celery -A tasks worker --loglevel=info &

# 启动 Flask (使用 Gunicorn 生产级服务器)
# -w 4: 4个工作进程
# -b 0.0.0.0:5000: 监听端口
exec gunicorn -w 4 -b 0.0.0.0:5000 app:app

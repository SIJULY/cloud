#!/bin/bash

# 启动 Celery Worker (后台运行)
celery -A tasks worker --loglevel=info &

# 启动 Flask (使用 Gunicorn)
# -w 4: 启动 4 个工作进程 (占用内存的主力)
# --threads 10: 每个进程开启 10 个线程 (处理并发的主力，处理上传下载非常有效)
# -b 0.0.0.0:5000: 监听端口
# --timeout 0: 【关键】设置为 0 代表永不超时，直到上传完成
exec gunicorn -w 4 --threads 10 -b 0.0.0.0:5000 --timeout 0 app:app

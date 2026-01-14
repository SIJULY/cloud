import os
import shutil
import time
from pathlib import Path
from nicegui import ui, app
from fastapi import UploadFile
from fastapi.responses import FileResponse

# --- 基础配置 ---
STORAGE_ROOT = Path("/app/data").resolve()
STORAGE_ROOT.mkdir(exist_ok=True, parents=True)

class ProWebDisk:
    def __init__(self):
        self.current_rel_path = Path(".")
        self.search_val = ""
        self.selected = set()
        
    @property
    def current_full_path(self):
        return (STORAGE_ROOT / self.current_rel_path).resolve()

    def get_disk_usage(self):
        total, used, free = shutil.disk_usage(STORAGE_ROOT)
        return used, total, used / total

    def format_size(self, size):
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if size < 1024: return f"{size:.1f}{unit}"
            size /= 1024
        return f"{size:.1f}PB"

    def navigate_to(self, rel_path):
        self.current_rel_path = Path(rel_path)
        self.selected.clear()
        self.render_view.refresh()

    async def handle_upload(self, e):
        # 处理大文件上传逻辑
        target = self.current_full_path / e.name
        with open(target, 'wb') as f:
            f.write(e.content.read())
        ui.notify(f'上传完成: {e.name}', type='positive')
        self.render_view.refresh()

    @ui.refreshable
    def render_view(self):
        # 1. 面包屑导航栏
        with ui.row().classes('items-center p-2 text-gray-500 text-sm'):
            ui.icon('home', size='xs').on('click', lambda: self.navigate_to('.'))
            path_acc = Path('.')
            for part in self.current_rel_path.parts:
                if part == '.': continue
                path_acc /= part
                ui.label('/')
                ui.button(part, on_click=lambda _, p=path_acc: self.navigate_to(p)).props('flat dense no-caps').classes('text-blue-600')

        # 2. 文件列表头
        with ui.row().classes('w-full border-b pb-2 text-gray-400 text-xs px-4'):
            ui.checkbox().props('dense')
            ui.label('文件名').classes('flex-grow ml-4')
            ui.label('大小').classes('w-24 text-right')
            ui.label('修改时间').classes('w-40 text-right')

        # 3. 循环渲染文件
        try:
            items = sorted(os.scandir(self.current_full_path), key=lambda e: (not e.is_dir(), e.name))
            for entry in items:
                if self.search_val and self.search_val.lower() not in entry.name.lower():
                    continue
                
                stats = entry.stat()
                mtime = time.strftime('%Y.%m.%d %H:%M', time.localtime(stats.st_mtime))
                is_dir = entry.is_dir()
                
                with ui.row().classes('w-full items-center p-3 hover:bg-blue-50 rounded group cursor-pointer transition-all'):
                    ui.checkbox().props('dense')
                    icon = 'folder' if is_dir else 'insert_drive_file'
                    color = 'blue-4' if is_dir else 'grey-5'
                    ui.icon(icon, color=color, size='md')
                    
                    name_label = ui.label(entry.name).classes('flex-grow ml-3 truncate text-sm font-medium text-gray-700')
                    
                    # 交互逻辑：文件夹双击进入，文件点击下载
                    if is_dir:
                        name_label.on('dblclick', lambda _, n=entry.name: self.navigate_to(self.current_rel_path / n))
                    else:
                        name_label.on('click', lambda _, n=entry.name: ui.download(f'/dl/{self.current_rel_path / n}'))

                    ui.label(self.format_size(stats.st_size) if not is_dir else '文件夹').classes('w-24 text-right text-xs text-gray-500')
                    ui.label(mtime).classes('w-40 text-right text-xs text-gray-400')
        except Exception as e:
            ui.label(f'加载失败: {e}').classes('p-10 text-red-400')

    def build_layout(self):
        # 侧边栏
        with ui.left_drawer(fixed=True).style('background-color: #f4f7f9').props('width=240'):
            with ui.column().classes('w-full p-6'):
                ui.label('小龙女她爸').classes('text-xl font-bold')
                ui.badge('✨ 开发者模式', color='blue-1 text-blue-800').classes('mt-1 px-2')
            
            with ui.list().classes('w-full px-2 mt-4'):
                ui.list_item('个人文件', icon='folder_shared').classes('bg-blue-100 text-blue-700 rounded-lg')
                ui.list_item('家庭共享', icon='family_restroom')
                ui.list_item('传输列表', icon='sync_alt')
                ui.separator().classes('my-4')
                ui.list_item('回收站', icon='delete_sweep')
            
            # 底部容量显示
            with ui.column().classes('absolute-bottom p-6'):
                used, total, ratio = self.get_disk_usage()
                ui.linear_progress(value=ratio, color='blue').classes('h-1.5 rounded-full')
                with ui.row().classes('w-full justify-between text-[10px] mt-2 text-gray-400 font-mono'):
                    ui.label(f"{self.format_size(used)} / {self.format_size(total)}")
                    ui.label('扩容').classes('text-blue-500 cursor-pointer')

        # 主内容区
        with ui.column().classes('w-full h-full p-0'):
            # 顶栏工具栏
            with ui.row().classes('w-full items-center justify-between p-4 border-b bg-white'):
                with ui.row().classes('items-center gap-3'):
                    ui.button(icon='arrow_back', on_click=lambda: self.navigate_to(self.current_rel_path.parent)).props('flat round dense')
                    with ui.button('上传', icon='cloud_upload').props('unelevated color=blue-6 rounded'):
                        with ui.menu().classes('p-4'):
                            ui.upload(on_upload=self.handle_upload, multiple=True, auto_upload=True, label='选择文件').classes('w-64')
                    ui.button('分享', icon='share').props('outline color=grey-7 size=sm')
                    ui.button('更多', icon='more_horiz').props('outline color=grey-7 size=sm')

                with ui.input(placeholder='搜索文件名...', on_change=lambda e: setattr(self, 'search_val', e.value) or self.render_view.refresh()).props('rounded outlined dense bg-color=grey-1'):
                    with ui.add_slot('prepend'): ui.icon('search')

            # 文件视图
            with ui.scroll_area().classes('flex-grow w-full px-6 py-4'):
                self.render_view()

disk = ProWebDisk()

@app.get('/dl/{path:path}')
async def download(path: str):
    return FileResponse(STORAGE_ROOT / path)

@ui.page('/')
def main():
    disk.build_layout()

ui.run(title='CloudDisk Pro', port=8080, storage_secret='your_secret_key')

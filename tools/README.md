# LinguaVerse 开发工具

## 已安装工具

| 工具 | 版本 | 路径 | 启动方式 |
|------|------|------|---------|
| Godot | 4.7.2-stable | `Godot_v4.7.2-stable_linux.x86_64` | `./Godot_v4.7.2-stable_linux.x86_64` |
| Blender | 4.2.8 LTS | `blender-4.2.8-linux-x64/blender` | `./blender-4.2.8-linux-x64/blender` |

## 快捷命令

```bash
# 从项目根目录启动 Godot 编辑器
./tools/Godot_v4.7.2-stable_linux.x86_64 --editor

# 从项目根目录启动 Blender
./tools/blender-4.2.8-linux-x64/blender

# 命令行创建 Godot 项目
./tools/Godot_v4.7.2-stable_linux.x86_64 --headless --path . --create-project godot-project
```

## 注意事项

- Godot Web 导出需要下载导出模板（在 Godot 编辑器中：Editor → Manage Export Templates）
- Blender 可用于制作 3D 资产，导出为 glTF 格式供 Godot 导入

# Linux 适配分析

**核心问题：** Godot 和 R3F 在 Linux 上的适配程度如何？

---

## 一、Godot 在 Linux 上

### 1.1 官方支持

| 项目 | 数据 |
|------|------|
| 最新版本 | 4.7.2-stable |
| Linux 构建 | ✅ 官方提供（x86_64 / x86_32 / arm64 / arm32） |
| 包体大小 | ~76 MB（标准版）/ ~105 MB（Mono/C# 版） |
| 许可证 | MIT（完全免费） |

### 1.2 Linux 安装方式

```bash
# 方式1：下载官方构建
wget https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip
unzip Godot_v4.7.2-stable_linux.x86_64.zip

# 方式2：通过包管理器（Ubuntu/Debian）
# Godot 官方提供 AppImage 格式，下载即可运行

# 方式3：Flatpak
flatpak install flathub org.godotengine.Godot
```

### 1.3 Linux 上的功能完整度

| 功能 | Linux 支持 | 说明 |
|------|-----------|------|
| 3D 渲染 | ✅ Vulkan / OpenGL | 与 Windows/macOS 一致 |
| 编辑器 | ✅ 完整功能 | 与 Windows/macOS 一致 |
| GDScript | ✅ 完整支持 | 与 Windows/macOS 一致 |
| C# (Mono) | ✅ 完整支持 | 需要 .NET SDK |
| Web 导出 | ✅ 支持 | 导出 HTML5/WebGL |
| 音频 | ✅ 支持 | PulseAudio / ALSA |
| 输入设备 | ✅ 支持 | 键盘/鼠标/手柄 |

**结论：** Godot 在 Linux 上是**一等公民**，功能与 Windows/macOS 完全一致。

### 1.4 已知问题

| 问题 | 严重度 | 说明 |
|------|--------|------|
| Wayland 支持 | ⚠️ 中 | 部分发行版 Wayland 下有兼容问题 |
| NVIDIA 驱动 | ⚠️ 低 | Vulkan 渲染需要较新的 NVIDIA 驱动 |
| 高 DPI | ⚠️ 低 | 部分桌面环境下缩放显示异常 |

---

## 二、R3F 在 Linux 上

### 2.1 本质：Web 技术

R3F 是 Web 技术栈（Three.js + React），**与操作系统无关**。

| 项目 | 数据 |
|------|------|
| 运行环境 | 任何现代浏览器（Chrome/Firefox/Edge） |
| 开发工具 | VS Code + Node.js + pnpm |
| 平台依赖 | 无（纯 Web） |

### 2.2 Linux 上的开发体验

```bash
# 开发环境（与任何 OS 相同）
node --version  # v26.8.1 ✅
pnpm --version  # 11.3.0 ✅
git --version   # 2.55.0 ✅

# 启动开发服务器
pnpm dev  # http://localhost:5173
```

### 2.3 Linux 上的功能完整度

| 功能 | Linux 支持 | 说明 |
|------|-----------|------|
| 3D 渲染 | ✅ 浏览器原生 | 取决于浏览器和 GPU 驱动 |
| 开发工具 | ✅ VS Code | 原生支持 Linux |
| Node.js | ✅ 官方支持 | Linux 是主要开发平台 |
| Vite | ✅ 完整支持 | 与任何 OS 一致 |
| 浏览器调试 | ✅ Chrome DevTools | 与任何 OS 一致 |
| HMR 热更新 | ✅ 完整支持 | 与任何 OS 一致 |

**结论：** R3F 在 Linux 上**完全没有问题**，因为它是 Web 技术。

---

## 三、对比

| 维度 | Godot (Linux) | R3F (Linux) |
|------|--------------|-------------|
| **安装** | 下载 AppImage / Flatpak | npm install（已安装） |
| **启动** | 双击运行 / 命令行 | pnpm dev |
| **编辑器** | ✅ 原生 GUI 编辑器 | ⚠️ VS Code + Blender |
| **调试** | ✅ 内置调试器 | ✅ Chrome DevTools |
| **构建** | 导出 Web / Desktop | pnpm build |
| **性能** | ✅ 原生性能 | ✅ 浏览器性能 |
| **社区支持** | ✅ Linux 是一等公民 | ✅ Web 与 OS 无关 |

---

## 四、结论

**两者在 Linux 上都没有问题。**

| 选择 | Linux 适配 | 说明 |
|------|-----------|------|
| Godot | ✅ 完美 | 原生 Linux 支持，功能完整 |
| R3F | ✅ 完美 | Web 技术，与 OS 无关 |

**Linux 不是决定因素。** 决定因素仍然是：
- 语宙是 Web 应用 → R3F
- 语宙需要专业场景编辑 → Godot 或 Blender

---

## 五、建议

由于你的开发环境是 Linux：

1. **如果选 R3F** → 直接开始，不需要额外安装任何东西
2. **如果选 Godot** → 下载 AppImage 即可运行，但 Web 导出的包体和加载时间仍然是问题
3. **如果用 Blender** → Blender 也有 Linux 版本，下载即用

**Linux 不影响最终决定。**
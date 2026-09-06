# 语宙（LinguaVerse）

**探索巴黎街区，用法语和世界对话。**

沉浸式语言学习游戏——POV 开放世界 + AI 自由对话 + 情景涌现。

---

## 项目状态

| 阶段 | 状态 |
|------|------|
| 设计文档 | ✅ 完成（16+ 项决策锁定） |
| 技术调研 | ✅ 完成（引擎对比、资产方案、LLM API） |
| Web 集成方案 | ✅ 完成（JavaScriptBridge + DOM 叠加） |
| 工具安装 | ✅ Godot 4.7.2 + Blender 4.2.8 |
| 项目骨架 | ✅ 创建完成 |
| 技术验证（PoC） | ⏳ 待进行 |
| 资产制作 | ⏳ 待进行 |

## 快速开始

```bash
# 启动 Godot 编辑器
./tools/Godot_v4.7.2-stable_linux.x86_64 --editor --path godot-project

# 启动 Blender 制作资产
./tools/blender-4.2.8-linux-x64/blender
```

## 项目结构

```
LinguaVerse/
├── godot-project/          # Godot 项目（主项目）
│   ├── project.godot       # 项目配置
│   ├── scenes/             # 场景文件
│   ├── scripts/            # GDScript 脚本
│   │   ├── player/         # 第一人称控制器
│   │   ├── npc/            # NPC 系统
│   │   ├── dialog/         # 对话系统
│   │   ├── world/          # 世界系统（昼夜循环）
│   │   └── autoload/       # 全局单例
│   └── assets/             # 3D 资产
├── backend/                # Node.js AI 网关（待创建）
├── blender-assets/         # Blender 源文件（待创建）
├── docs/                   # 设计文档
└── tools/                  # 开发工具（Godot + Blender）
```

## 技术栈

| 层 | 选型 | 说明 |
|----|------|------|
| 游戏引擎 | Godot 4.7.2 | 场景搭建、渲染、物理、动画 |
| 3D 资产 | Blender 4.2.8 | 建筑、家具、NPC 模型 |
| 脚本语言 | GDScript | 游戏逻辑、NPC 行为 |
| AI 网关 | Node.js + Fastify | LLM API 统一接口 |
| Web UI | JavaScriptBridge + DOM | 对话输入框、台词气泡 |
| LLM（开发） | Ollama + Qwen2.5 | 本地零成本开发 |
| LLM（生产） | DeepSeek / OpenAI | 云 API |

## 设计核心

1. **NPC 不是老师，是居民** —— 只会过自己的生活
2. **失败即成长** —— 没有 Game Over，所有失败被世界消化
3. **探索即进度** —— 只要移动就在进步
4. **情景即课本** —— 咖啡馆点单就是一堂课
5. **最小 HUD，最大世界** —— 没有经验条、任务列表

## 文档索引

- [技术调研报告](docs/技术调研报告.md)
- [引擎对比分析](docs/引擎对比分析.md)
- [Godot 对比分析](docs/Godot对比分析.md)
- [Linux 适配分析](docs/Linux适配分析.md)
- [系统规则设计](docs/系统规则设计讨论稿.md)
- [设计决策锁定](docs/设计决策锁定记录.md)
- [技术选型（V1 垂直切片）](docs/技术选型-巴黎咖啡馆垂直切片.md)
- [Godot Web 集成方案](docs/Godot-Web集成技术方案.md)

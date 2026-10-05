# 语宙（LinguaVerse）

**探索巴黎街区，用法语和世界对话。**

沉浸式语言学习游戏——POV 开放世界 + AI 自由对话 + 情景涌现。

---

## 项目状态

| 阶段 | 状态 |
|------|------|
| 设计文档 | ✅ 完成（16+ 项决策锁定） |
| 技术调研 | ✅ 完成（引擎对比、资产方案、LLM API） |
| Web 集成方案 | ✅ 完成（JavaScriptBridge + DOM 叠加，V2 实现） |
| 工具安装 | ✅ Godot 4.7.2 + Blender 4.2.8 |
| 项目骨架 | ✅ 创建完成（含后端 AI 网关） |
| **巴黎街景（Rue des Rosiers）** | ✅ **S1-S5 完成**（OSM 数据 → Godot 生成街景 + Blender 咖啡馆） |
| 世界活性（P1-4） | ✅ 行道树/路灯/长椅/施工围栏 + 昼夜实时跟随（`LV_FIXED_HOUR` 演示锁；headless 27 项 0 失败） |
| 对话系统 | ✅ 键盘输入 + AI 网关 + NPC 触发 + 走开/ESC 自然结束 + NPC 思考动作/气泡名牌（headless 46 项断言） |
| 环境音（P1-5，决策 10） | ✅ 程序合成 CC0 零下载：街道/咖啡馆循环 + 杯碟音效（`check_audio` 52 项离线校验，不含主观听感） |
| 验证体系 | ✅ `tools/verify.sh` **10 步**全绿（结构 + 闭环回放 + GLB/音频哈希绑定校验 + 冒烟 + 帧采样 + 对话回归），报告含 scope 自陈 |
| 技术验证（PoC） | ✅ 结构自检 0 失败 + 路径可达性验证通过 |
| 资产制作 | 🟡 部分完成（咖啡馆 .glb ✅；更多家具/道具待做） |
| 视觉验收 | ⏳ 待真实 GPU 目检（沙箱软渲染有色差） |

> **V1 平台：** Godot Desktop（Linux/Windows/macOS）。Web 导出在 V2 实现。

**最近更新：** 2026-10-05 V1 收尾 P1 落地：NPC 思考动作掩盖 LLM 延迟（决策 6）、气泡/名牌打磨、世界活性最低项（树/灯/椅/围栏 + 昼夜实时）、程序合成环境音（决策 10，CC0 零下载）；`tools/verify.sh` 扩至 10 步全绿——**不能据此声称**视觉/听觉/真机体验验收（本机无 GPU，llvmpipe 截图与 headless 断言仅作结构与位置抽查）

## 快速开始

```bash
# 一键验证（10 步：结构断言 + 资产/音频校验 + 后端冒烟 + 对话回归）
tools/verify.sh

# 启动 Godot 编辑器
./tools/Godot_v4.7.2-stable_linux.x86_64 --editor --path godot-project

# 启动 Blender 制作资产
./tools/blender-4.2.8-linux-x64/blender

# 启动后端 AI 网关
cd backend && cp .env.example .env && pnpm install && pnpm dev
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
├── backend/                # Node.js AI 网关（LLM 统一接口）
├── data/                   # OSM 原始数据（Overpass 拉取存档）
├── docs/                   # 设计文档
└── tools/                  # 开发工具 + 生成脚本
    ├── Godot_v4.7.2...     # Godot 引擎
    ├── blender-4.2.8...    # Blender
    ├── osm_to_layout.py    # OSM → 街景布局（S1）
    ├── build_cafe.py       # Blender 咖啡馆建模（S3）
    ├── make_ambience.py    # 程序合成环境音（CC0，零下载）
    └── check_audio.py      # 音频离线校验（无缝循环/峰值/确定性）
```

## 技术栈

| 层 | 选型 | 说明 |
|----|------|------|
| 游戏引擎 | Godot 4.7.2 | 场景搭建、渲染、物理、动画 |
| 3D 资产 | Blender 4.2.8 | 建筑、家具、NPC 模型 |
| 脚本语言 | GDScript | 游戏逻辑、NPC 行为 |
| AI 网关 | Node.js + Fastify | LLM API 统一接口 |
| Web UI（V2） | JavaScriptBridge + DOM | 对话输入框、台词气泡 |
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
- [项目进度](docs/项目进度.md)
- [V1 开发计划](docs/V1开发计划.md)
- [V1 收尾开发方案](docs/V1收尾-开发方案.md)
- [巴黎场景搭建-实施计划](docs/巴黎场景搭建-实施计划.md)
- [Godot Web 集成方案（V2 参考）](docs/Godot-Web集成技术方案.md)
- [巴黎数字孪生技术方案](docs/巴黎数字孪生技术方案.md)
- [性能优化与模型灵活性](docs/性能优化与模型灵活性.md)
- [整个巴黎技术方案](docs/整个巴黎-技术方案.md)

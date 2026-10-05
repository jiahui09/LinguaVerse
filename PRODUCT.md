# Product

<!-- impeccable:product-schema 1 -->

## Platform

desktop（Godot 4.7，Linux/Windows 桌面端；impeccable 平台值域为 web/ios/android/adaptive，无 desktop——按实记录并声明此偏差。Web 导出为 V2 目标，见设计决策 17）

## Users

- **主要用户：** 想通过沉浸式体验学法语的成人学习者（零基础到进阶均可——决策 3：NPC 在固定语言能力范围内按玩家水平调整说话方式）。情境：桌面端独自打开、无注册零门槛进入（决策 12），前 5 分钟内完成第一次自然法语对话。

## Product Purpose

POV 探索以真实 OSM 数据为骨架的巴黎街区，与 LLM 驱动的 NPC 居民进行非锁定式自由法语对话，用"生活在语言环境里"替代课堂练习。成功 = V1 体验闭环（进入街头 → 走进咖啡馆 → 被招呼 → 键盘法语点单 → 咖啡端来 → 走出继续探索 → 昼夜与作息变化）且验证核心假设：POV 自由探索比场景选择更能引发探索欲、LLM 对话比预设脚本更自然、昼夜让世界感觉"活"。

## Positioning

邻近产品无法照搬的组合机制：真实 OSM 巴黎街区（地理真实）＋ 非锁定式对话（决策 9：走近、回应、走开，没有"退出对话按钮"）＋ 居民式 NPC（规则 4：不是老师，听不懂就是听不懂——决策 4）＋ 失败由世界消化（规则 3：无 Game Over、无扣分、无惩罚）。

## Operating Context

- **开发与验证：** `./tools/verify.sh` 一键 10 步（结构/回放/GLB/音频/冒烟/回归），报告落 `artifacts/verify-report.json`，输入 SHA256 哈希绑定 + scope 字段自陈"不能据此声称"。
- **运行时：** Godot 桌面客户端 + Fastify 后端网关（backend/，Ollama/DeepSeek/OpenAI 适配器，可插拔）；无后端时优雅降级不崩溃。
- **内容管线：** Python 纯标准库工具（OSM→布局、咖啡馆 glb、CC0 环境音确定性合成）；Blender 4.2.8 资产；数据存档 `data/osm/`。
- **协作与交付：** 文档驱动（docs/ 设计决策锁定记录先行），main 直改、中文 Conventional Commits、jiahui 身份（git-identity / branching-workflow 规程）。

## Capabilities and Constraints

**已确认能力（V1 收尾后）：** POV 移动（WASD+鼠标）；3 个 NPC（Marie 咖啡师 / Pierre 巡警 / Jean 老人，法语职业副名牌）；非锁定多轮键盘对话 + 思考动作掩盖延迟；点单→咖啡端来世界反馈；昼夜实时同步 + `LV_FIXED_HOUR` 演示锁；街道道具（树/灯/椅/自然边界围栏）；CC0 环境音街面/店内交叉淡变；10 步一键验证。

**约束（锁定决策与规则）：**
- 决策 4：NPC 语言能力固定，听不懂就是听不懂（世界观红线）。
- 决策 12 + 规则 6：零门槛直接进入、最小 HUD（无经验条、无任务列表、无分数）。
- V1 明确排除（V2+ 才做）：语音输入、纠错高亮、复盘卡片、发音训练、文化百科、天气系统、空间音频、母语桥接。
- 无真机 GPU 环境：视觉/听感/帧率不得作验收声称（llvmpipe 截图仅位置抽查）。

**未决产品事实（不臆造）：**
- 巴黎扩展的分阶段方案以 `docs/巴黎扩展-实施方案.md` 定稿为准（本轮规划产出）。
- 决策 8（NPC 暂限 3 个）在多街区阶段需重新裁决。
- 本轮操作逻辑范围按访谈锁定：仅对话交互、不加引导系统、不加新情景。

## Brand Commitments

- **名称：** 语宙 LinguaVerse；界面与文档中文，游戏内世界语言法语。
- **声音：** 真实、无教学腔——NPC 绝不说"让我教你……"（规则 4）。
- **绑定资产：** Rue des Rosiers OSM 存档、`cafe.glb`、CC0 环境音（`tools/make_ambience.py` 确定性合成，零第三方素材）。
- **诚实纪律（品牌红线）：** 每个 ✅ 必须写明验证 scope 与"不能据此声称"；AI 生成法语内容默认 `ai-drafted`，不得呈称为母语者说法（GTA_SZ 证据分级迁移）。

## Evidence on Hand

- `artifacts/verify-report.json`——10 步全绿、绑定提交、含 scope 自陈。
- 断言规模：street_check 27 项 / dialog_check 46 项 / playthrough_check 36 项 / check_audio 52 项。
- `godot-project/screenshots/`——llvmpipe 软渲染截图（**仅位置抽查，不是视觉验收证据**）。
- `data/assets_manifest.json`——资产 SHA256 清单（含音频来源与生成器哈希）。
- **缺席（后续工作不得伪造）：** 真机 GPU 视觉/帧率验收、真人听感评估、母语者对法语内容的审定、Phase 6 打包产物。

## Product Principles

1. **沉浸优先：** 任何让玩家感觉"我在做练习"的设计都是失败（系统规则前提）。
2. **最小工作量 × 最高体验：** 每个功能先问"必须还是可以没有"。
3. **最小 HUD、最大世界：** 进度是探索的副产品，收益活在世界反馈里（规则 1 + 规则 6）。
4. **世界真实运转：** NPC 是居民不是老师；失败被世界消化为自然反应（规则 3/4）。
5. **诚实验证：** 结论只声称其证据能证明的范围；机器判定优先于主观表述（GTA_SZ 迁移）。

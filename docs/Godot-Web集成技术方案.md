# Godot Web 集成技术方案

**目标：** 解决 Godot Web 导出的所有关键技术障碍
**日期：** 2026-09-06
**状态：** ✅ 方案已确认（基于 Godot 4 官方文档验证）

---

## 〇、为什么选 Godot 而非 R3F

前三份分析文档（引擎对比、Godot 对比、技术调研）都指向 R3F，但最终决策 17 选择了 Godot。以下是推翻 R3F 结论的理由：

| R3F 的优势（分析文档强调的） | 实际情况 | Godot 的对应能力 |
|---|---|---|
| 加载快（1-3 秒） | 对 V1 验证阶段不是决定性因素 | Godot Web 导出 5-15 秒，可接受 |
| React/TS 集成 | 语宙不是 React 应用，3D 场景不需要 React | GDScript 专为游戏设计 |
| 原生 fetch/SSE | 可以通过 JavaScriptBridge 解决 | HTTPRequest + JS 互操作 |
| 包体小 | V1 是验证阶段，包体不是核心指标 | 10-30 MB 可接受 |

| Godot 的核心优势（分析文档低估的） | 说明 |
|---|---|
| **专业级场景编辑器** | 所见即所得搭建巴黎街景，效率远超 Blender + 代码 |
| **内置物理/动画/粒子** | NPC 动画、角色控制器、碰撞检测全部内置 |
| **完整的游戏开发工作流** | 从原型到发布一站式，不需要拼凑多个工具 |
| **桌面端原生性能** | 未来做桌面版无需额外工作 |
| **116k+ stars 社区** | 资源丰富，问题容易找到解决方案 |
| **GDScript 专用性** | 比 TypeScript 更适合游戏逻辑（状态机、信号、节点树） |

**关键认知：** R3F 的优势主要在"与 Web 前端集成"，但语宙的核心体验是 **3D 沉浸式场景**，不是 React 组件。Godot 是为这个场景设计的工具。

---

## 一、Godot Web 导出能力概览

### 1.1 导出格式

| 格式 | 说明 | 推荐度 |
|------|------|--------|
| **HTML5/WebGL** | 浏览器可运行，Canvas 渲染 | ✅ V1 主要目标 |
| **Linux Desktop** | 原生二进制 | ✅ 开发调试用 |
| **Windows Desktop** | 原生二进制 | ⚠️ 未来需要时 |

### 1.2 Web 导出的包体组成

```
Godot Web 导出包体：
├── 引擎运行时（WASM）：~8-15 MB
├── 游戏资产（模型/纹理/音频）：1-5 MB
├── 总计：9-20 MB
└── 首次加载：5-15 秒（取决于网络和缓存）
```

### 1.3 性能预期

| 场景复杂度 | 预期帧率 | 说明 |
|-----------|---------|------|
| V1 场景（15k-30k 面） | 40-60 fps | 桌面浏览器 |
| V1 场景（移动端 Web） | 20-40 fps | 可接受 |

---

## 二、UI 集成方案（对话输入框）

### 2.1 问题

Godot Web 导出运行在隔离的 Canvas 中，无法直接使用 HTML DOM。

### 2.2 解决方案：JavaScriptBridge + DOM 叠加（✅ 官方文档确认）

Godot 4 提供 `JavaScriptBridge` 单例（仅 Web 平台可用），允许 GDScript 与 JavaScript 互操作。

**官方 API（来自 Godot 4 文档 `tutorials/platform/web/javascript_bridge.rst`）：**

| 方法 | 用途 |
|------|------|
| `JavaScriptBridge.eval(code)` | 执行 JavaScript 代码字符串 |
| `JavaScriptBridge.get_interface(name)` | 获取全局 JS 对象（如 `"window"`, `"document"`） |
| `JavaScriptBridge.create_object(name, ...)` | 调用 JS `new` 构造函数 |
| `JavaScriptBridge.create_callback(method)` | 创建 GDScript 函数的 JS 回调（⚠️ 必须接受一个 `Array` 参数） |

**方案：对话输入框用 HTML/CSS 实现，叠加在 Godot Canvas 上方。**

```gdscript
# 在 GDScript 中调用 JavaScript（使用 eval）
func _ready():
    if OS.has_feature('web'):
        JavaScriptBridge.eval("""
            // 创建对话输入框
            const inputDiv = document.createElement('div');
            inputDiv.id = 'dialog-input';
            inputDiv.innerHTML = '<input type="text" id="player-input" placeholder="Type in French..."><button id="send-btn">Envoyer</button>';
            document.body.appendChild(inputDiv);
            
            // 样式：固定在屏幕底部
            const style = document.createElement('style');
            style.textContent = `
                #dialog-input {
                    position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%);
                    z-index: 1000; display: none;
                    background: rgba(0,0,0,0.7); padding: 10px 20px; border-radius: 10px;
                }
                #player-input { width: 300px; padding: 8px; border-radius: 5px; border: none; }
                #send-btn { padding: 8px 16px; margin-left: 8px; border-radius: 5px; border: none; 
                             background: #4CAF50; color: white; cursor: pointer; }
            `;
            document.head.appendChild(style);
        """)
```

### 2.3 GDScript ↔ JavaScript 通信（✅ 官方回调机制确认）

```gdscript
# ⚠️ 关键：回调函数必须接受一个 Array 参数（JS arguments 对象转换而来）
var _dialog_callback = JavaScriptBridge.create_callback(_on_player_input)

func _ready():
    if OS.has_feature('web'):
        # 获取 document 对象
        var document = JavaScriptBridge.get_interface("document")
        # 注册按钮点击事件，调用 GDScript 回调
        JavaScriptBridge.eval("""
            document.getElementById('send-btn').addEventListener('click', function() {
                var input = document.getElementById('player-input').value;
                if (input.trim()) {
                    window.godotOnPlayerInput(input);
                    document.getElementById('player-input').value = '';
                }
            });
        """)
        # 将回调暴露给全局作用域
        var window = JavaScriptBridge.get_interface("window")
        window.godotOnPlayerInput = _dialog_callback

# GDScript → JavaScript：显示输入框
func show_dialog_input():
    JavaScriptBridge.eval("document.getElementById('dialog-input').style.display = 'block';")
    JavaScriptBridge.eval("document.getElementById('player-input').focus();")

# JavaScript → GDScript：接收玩家输入（注意：参数是 Array）
func _on_player_input(args):
    var player_text = args[0] as String
    print("Player said: ", player_text)
    # 发送到 AI 网关...
```

### 2.4 台词气泡（NPC 说话）

```gdscript
# NPC 台词用 HTML 气泡显示
func show_npc_bubble(npc_name: String, text: String):
    var escaped_text = text.replace('"', '\\"')
    JavaScriptBridge.eval('''
        var bubble = document.getElementById('npc-bubble');
        if (!bubble) {
            bubble = document.createElement('div');
            bubble.id = 'npc-bubble';
            document.body.appendChild(bubble);
        }
        bubble.innerHTML = '<div class="npc-name">''' + npc_name + '''</div><div class="npc-text">''' + escaped_text + '''</div>';
        bubble.style.display = 'block';
        setTimeout(function() { bubble.style.display = 'none'; }, 3000);
    ''')
```

---

## 三、HTTP 通信方案（AI 网关）

### 3.1 方案选择

| 方案 | 说明 | 推荐度 |
|------|------|--------|
| **A: Godot HTTPRequest** | 内置节点，支持 HTTP 请求 | ✅ 简单请求（V1 够用） |
| **B: JavaScript fetch** | 通过 JavaScriptBridge 调用 fetch | ✅ 流式响应（SSE） |
| **C: Head Include + axios** | 导出时加载 axios 库，GDScript 调用 | ✅ 官方推荐方式 |

### 3.2 方案 A：HTTPRequest 节点（简单请求，V1 推荐）

```gdscript
# 创建 HTTPRequest 节点
var http_request = HTTPRequest.new()
add_child(http_request)
http_request.request_completed.connect(_on_response)

# 发送对话请求
func send_dialog(player_input: String, npc_id: String):
    var url = "http://localhost:3000/api/dialog"
    var headers = ["Content-Type: application/json"]
    var body = JSON.stringify({
        "player_input": player_input,
        "npc_id": npc_id,
        "world_state": get_world_state()
    })
    http_request.request(url, headers, HTTPClient.METHOD_POST, body)

func _on_response(result, response_code, headers, body):
    var json = JSON.new()
    json.parse(body.get_string_from_utf8())
    var response = json.data
    show_npc_bubble(response.npc_name, response.text)
```

### 3.3 方案 B：JavaScript fetch（流式 SSE，V2 升级用）

```gdscript
# 流式响应通过 JavaScript ReadableStream 实现
# ⚠️ 注意：回调必须接受 Array 参数
var _stream_callback = JavaScriptBridge.create_callback(_on_stream_chunk)

func _ready():
    if OS.has_feature('web'):
        var window = JavaScriptBridge.get_interface("window")
        window.godotOnStreamChunk = _stream_callback

func send_dialog_streaming(player_input: String, npc_id: String):
    var escaped_input = player_input.replace('"', '\\"')
    JavaScriptBridge.eval('''
        fetch('http://localhost:3000/api/dialog/stream', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                player_input: "''' + escaped_input + '''",
                npc_id: "''' + npc_id + '''"
            })
        }).then(function(response) {
            var reader = response.body.getReader();
            var decoder = new TextDecoder();
            var buffer = '';
            
            function read() {
                reader.read().then(function(result) {
                    if (result.done) return;
                    buffer += decoder.decode(result.value, { stream: true });
                    var lines = buffer.split('\\n');
                    buffer = lines.pop();
                    for (var line of lines) {
                        if (line.startsWith('data: ')) {
                            var data = JSON.parse(line.slice(6));
                            window.godotOnStreamChunk(data.text, data.done);
                        }
                    }
                    read();
                });
            }
            read();
        });
    ''')

# ⚠️ 参数是 Array（JS arguments 转换而来）
func _on_stream_chunk(args):
    var text = args[0] as String
    var done = args[1] as bool
    if done:
        print("Stream complete")
    else:
        # 逐字显示 NPC 回复
        append_to_bubble(text)
```

### 3.4 方案 C：Head Include + axios（官方推荐方式）

在 Godot 导出设置的 **Head Include** 中添加：

```html
<!-- axios 库（通过 CDN 加载） -->
<script src="https://cdn.jsdelivr.net/npm/axios/dist/axios.min.js"></script>
```

然后在 GDScript 中直接调用：

```gdscript
var _axios_callback = JavaScriptBridge.create_callback(_on_axios_response)

func _ready():
    if OS.has_feature('web'):
        var window = JavaScriptBridge.get_interface("window")
        window.godotOnAxiosResponse = _axios_callback

func send_dialog(player_input: String, npc_id: String):
    JavaScriptBridge.eval('''
        var axios = window.axios;
        axios.post('http://localhost:3000/api/dialog', {
            player_input: "''' + player_input.replace('"', '\\"') + '''",
            npc_id: "''' + npc_id + '''"
        }).then(function(response) {
            window.godotOnAxiosResponse(response.data);
        });
    ''')

func _on_axios_response(args):
    var data = args[0]
    show_npc_bubble(data.npc_name, data.text)
```

---

## 四、跨域（CORS）方案

### 4.1 问题

Godot Web 导出运行在 `http://localhost:xxxx`，后端运行在 `http://localhost:3000`，存在跨域限制。

### 4.2 解决方案

**开发阶段：后端配置 CORS 允许所有来源**

```javascript
// Fastify CORS 配置
import cors from '@fastify/cors';

await fastify.register(cors, {
    origin: true,  // 开发阶段允许所有来源
    methods: ['GET', 'POST'],
    allowedHeaders: ['Content-Type']
});
```

**生产阶段：同源部署**

```
方案 A：前端（Godot Web）和后端部署在同一域名下
  → https://linguaverse.app/ （Godot 静态文件）
  → https://linguaverse.app/api/* （后端 API）

方案 B：后端反向代理
  → Nginx 将 /api/* 转发到后端服务
```

---

## 五、项目结构

```
LinguaVerse/
├── godot-project/              # Godot 项目根目录
│   ├── project.godot           # Godot 项目配置
│   ├── export_presets.cfg      # 导出配置（Web + Desktop）
│   ├── scenes/                 # 场景文件
│   │   ├── main.tscn           # 主场景
│   │   ├── street/             # 街道场景
│   │   │   ├── paris_street.tscn
│   │   │   └── buildings/
│   │   ├── cafe/               # 咖啡馆场景
│   │   │   ├── cafe_interior.tscn
│   │   │   └── furniture/
│   │   └── ui/                 # UI 场景
│   │       ├── dialog_bubble.tscn
│   │       └── hud.tscn
│   ├── scripts/                # GDScript 脚本
│   │   ├── player/             # 玩家控制
│   │   │   ├── player_controller.gd
│   │   │   └── camera_controller.gd
│   │   ├── npc/                # NPC 系统
│   │   │   ├── npc_base.gd
│   │   │   ├── npc_waiter.gd
│   │   │   ├── npc_pedestrian.gd
│   │   │   └── npc_elder.gd
│   │   ├── dialog/             # 对话系统
│   │   │   ├── dialog_manager.gd
│   │   │   ├── dialog_api.gd
│   │   │   └── dialog_ui.gd
│   │   ├── world/              # 世界系统
│   │   │   ├── day_night_cycle.gd
│   │   │   ├── world_state.gd
│   │   │   └── ambient_sound.gd
│   │   └── autoload/           # 全局单例
│   │       ├── game_manager.gd
│   │       └── settings.gd
│   ├── assets/                 # 3D 资产
│   │   ├── models/             # glTF 模型
│   │   ├── textures/           # 纹理
│   │   ├── audio/              # 音效
│   │   │   ├── ambient/        # 环境音
│   │   │   └── sfx/            # 音效
│   │   └── fonts/              # 字体
│   └── addons/                 # Godot 插件
├── backend/                    # Node.js AI 网关
│   ├── package.json
│   ├── src/
│   │   ├── server.ts           # Fastify 服务
│   │   ├── routes/
│   │   │   └── dialog.ts       # 对话 API
│   │   ├── services/
│   │   │   ├── llm_gateway.ts  # LLM 统一接口
│   │   │   └── prompt_builder.ts # Prompt 组装
│   │   └── adapters/
│   │       ├── ollama.ts       # Ollama 适配器
│   │       ├── deepseek.ts     # DeepSeek 适配器
│   │       └── openai.ts       # OpenAI 适配器
│   └── tsconfig.json
├── blender-assets/             # Blender 源文件
│   ├── street/
│   ├── cafe/
│   └── characters/
├── docs/                       # 设计文档（已有）
└── README.md
```

---

## 六、开发工作流

```
1. Blender 制作资产 → 导出 glTF
2. Godot 导入 glTF → 在编辑器中搭建场景
3. 编写 GDScript 实现游戏逻辑
4. 本地运行 Godot 编辑器调试
5. 构建后端 API（Node.js + Fastify）
6. Web 导出 → 浏览器测试
7. Git push → 部署
```

### 开发工具

| 工具 | 用途 | 安装方式 |
|------|------|---------|
| Godot 4.x | 场景搭建、游戏逻辑 | AppImage / Flatpak |
| Blender | 3D 资产制作 | snap / AppImage |
| VS Code | 后端代码 + GDScript | 已安装 |
| GDScript 插件 | VS Code 中编写 GDScript | godot-tools 扩展 |
| Node.js | AI 网关 | 已安装 |

---

## 七、验证清单

| # | 验证项 | 方法 | 预期结果 | 状态 |
|---|--------|------|---------|------|
| 1 | JavaScriptBridge API | 官方文档确认 | ✅ eval/get_interface/create_callback 均可用 | ✅ 已确认 |
| 2 | GDScript ↔ JS 回调 | 官方文档确认 | ✅ create_callback + Array 参数 | ✅ 已确认 |
| 3 | DOM 操作 | 官方文档确认 | ✅ get_interface("document") + eval | ✅ 已确认 |
| 4 | 外部库加载 | 官方文档确认 | ✅ Head Include + get_interface | ✅ 已确认 |
| 5 | Godot Web 导出 | 安装后跑通 | 需实测 | ⏳ 待验证 |
| 6 | HTTPRequest 节点 | GDScript 请求后端 | 需实测 | ⏳ 待验证 |
| 7 | SSE 流式响应 | JavaScript fetch + ReadableStream | 需实测 | ⏳ 待验证 |
| 8 | glTF 导入 | Blender 导出 → Godot 导入 | 需实测 | ⏳ 待验证 |
| 9 | 第一人称控制 | PointerLock + WASD + 鼠标 | 需实测 | ⏳ 待验证 |
| 10 | Web 端性能 | V1 场景帧率 | 需实测 | ⏳ 待验证 |

---

## 八、风险与缓解

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| Godot Web 导出后性能差 | 中 | 高 | 场景足够小，不需要复杂优化 |
| JavaScriptBridge 不稳定 | 低 | 高 | Godot 4.x 已稳定，文档完善 |
| SSE 在 Godot Web 中不工作 | 中 | 中 | 降级为轮询（每秒请求一次） |
| glTF 导入有问题 | 低 | 中 | Godot 原生支持 glTF |
| 学习 GDScript 成本高 | 中 | 中 | GDScript 语法简单，1-2 天可上手 |

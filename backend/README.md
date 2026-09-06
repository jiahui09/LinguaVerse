# 语宙 AI 网关

Node.js + Fastify 后端，提供 LLM 统一对话接口。

## 快速开始

```bash
cd backend
cp .env.example .env          # 复制环境变量（默认用 Ollama）
pnpm install                  # 安装依赖
pnpm dev                      # 启动开发服务器（端口 3000）
```

## 前置条件

### 方案 A：Ollama（本地开发，零成本）

```bash
# 安装 Ollama
curl -fsSL https://ollama.com/install.sh | sh

# 拉取模型（法语支持较好的开源模型）
ollama pull qwen2.5:7b

# 确认运行
ollama list
```

### 方案 B：DeepSeek（生产，低成本）

在 `.env` 中设置：
```
LLM_PROVIDER=deepseek
DEEPSEEK_API_KEY=your-api-key-here
```

### 方案 C：OpenAI（备选）

在 `.env` 中设置：
```
LLM_PROVIDER=openai
OPENAI_API_KEY=your-api-key-here
```

## API 端点

### 健康检查

```
GET /api/health
→ { "status": "ok", "provider": "ollama" }
```

### 对话（非流式）

```
POST /api/dialog
Content-Type: application/json

{
  "player_input": "un café, s'il vous plaît",
  "npc_info": {
    "name": "Marie",
    "job": "咖啡馆服务员",
    "personality": "热情、忙碌",
    "speaks_french": true
  },
  "conversation_history": [],
  "world_state": {
    "time_of_day": "day",
    "player_position": { "x": 0, "y": 0, "z": 0 }
  }
}

→ { "text": "Un café, bien sûr! Café crème ou café noir?", "npc_name": "Marie" }
```

### 对话（流式 SSE）

```
POST /api/dialog/stream
Content-Type: application/json
（同上请求体）

→ SSE 流:
data: {"text": "Un", "done": false}
data: {"text": " café", "done": false}
data: {"text": "", "done": true}
```

## 项目结构

```
backend/
├── src/
│   ├── server.ts              # Fastify 服务入口
│   ├── routes/
│   │   └── dialog.ts          # 对话 API 路由
│   ├── services/
│   │   ├── llm_gateway.ts     # LLM 统一接口（适配器模式）
│   │   └── prompt_builder.ts  # Prompt 组装器
│   └── adapters/
│       ├── ollama.ts          # Ollama 适配器（本地）
│       ├── deepseek.ts        # DeepSeek 适配器（生产）
│       └── openai.ts          # OpenAI 适配器（备选）
├── package.json
├── tsconfig.json
├── .env.example
└── README.md
```

## curl 测试

```bash
# 健康检查
curl http://localhost:3000/api/health

# 对话测试
curl -X POST http://localhost:3000/api/dialog \
  -H "Content-Type: application/json" \
  -d '{
    "player_input": "Bonjour!",
    "npc_info": {"name": "Marie", "job": "serveuse", "personality": "热情", "speaks_french": true},
    "conversation_history": [],
    "world_state": {"time_of_day": "day", "player_position": {"x":0,"y":0,"z":0}}
  }'
```

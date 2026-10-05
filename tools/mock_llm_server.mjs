#!/usr/bin/env node
/**
 * 确定性 Mock 后端（P0-B4 闭环回放用）
 *
 * 模拟 /api/health、/api/dialog，不依赖 Ollama：回复按固定法语脚本轮换，
 * 使回放可断言（"回复 == 脚本第 N 句"）。支持切换失败模式，用于验证
 * 错误码 → 前端友好文案的端到端链路。
 *
 * 端点：
 *   GET  /api/health        → { status: 'ok', provider: 'mock' }
 *   POST /api/dialog        → { text, npc_name }（mode=fail 时返回 504 {code:'LLM_TIMEOUT'}）
 *   POST /__mode {mode}     → 切换 'ok' | 'fail'
 *   POST /__shutdown        → 退出进程
 * 超时保护：启动 300s 后自动退出，防止泄漏后台进程。
 */
import http from 'node:http';

const PORT = Number(process.env.MOCK_PORT || 3001);

// 固定脚本（法语）：回放脚本按 index 断言
const SCRIPT = [
  'Bonjour! Bienvenue au café.',
  'Très bien, un café crème. Un instant, s’il vous plaît.',
  'Voilà votre café. Bonne journée!',
  'Merci à vous, au revoir!',
  'D’accord, je vous écoute.',
];

let mode = 'ok';
let seq = 0;

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => (data += c));
    req.on('end', () => resolve(data));
  });
}

function json(res, status, obj) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
}

const server = http.createServer(async (req, res) => {
  const url = req.url || '';

  if (req.method === 'GET' && url.startsWith('/api/health')) {
    return json(res, 200, { status: 'ok', provider: 'mock' });
  }

  if (req.method === 'POST' && url.startsWith('/api/dialog')) {
    const raw = await readBody(req);
    let body = {};
    try {
      body = JSON.parse(raw || '{}');
    } catch {
      return json(res, 400, { code: 'LLM_BAD_OUTPUT' });
    }
    if (mode === 'fail') {
      return json(res, 504, { code: 'LLM_TIMEOUT' });
    }
    const text = SCRIPT[seq % SCRIPT.length];
    seq += 1;
    return json(res, 200, { text, npc_name: body?.npc_info?.name ?? 'NPC' });
  }

  if (req.method === 'POST' && url.startsWith('/__mode')) {
    const raw = await readBody(req);
    try {
      const m = JSON.parse(raw || '{}').mode;
      if (m === 'ok' || m === 'fail') mode = m;
    } catch {
      /* 保持当前模式 */
    }
    return json(res, 200, { mode });
  }

  if (req.method === 'POST' && url.startsWith('/__shutdown')) {
    json(res, 200, { status: 'shutting_down' });
    setTimeout(() => process.exit(0), 50);
    return;
  }

  json(res, 404, { code: 'NOT_FOUND' });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[mock] listening on http://localhost:${PORT}`);
});

setTimeout(() => {
  console.log('[mock] 超时自动退出（300s）');
  process.exit(0);
}, 300_000).unref?.();

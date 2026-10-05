#!/usr/bin/env node
/**
 * 对话质量/一致性回归（P0-B3）
 *
 * 固定法语脚本 × N 轮，对真实后端 + Ollama 打对话接口，度量：
 *  - 延迟 p50/p95/max（含首响应与总耗时）
 *  - 稳定契约：非空、≤2000 字符、法语特征（与网关同规则）、无底层错误泄漏
 *  - 中文输入场景：网关降级后仍应为法语安抚话术
 *
 * 报告：artifacts/dialog-regression-report.json（含 scope 自陈边界）
 * 退出码：0=通过；1=有失败或通过率 <95%；77=跳过（Ollama 不可达等）
 *
 * 用法：node tools/dialog_regression.mjs [--rounds 1] [--url http://localhost:3998]
 * verify.sh 会在后端不可用时自建 dist 后台实例（PORT=3998）。
 */
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const argv = process.argv.slice(2);
function argVal(name, def) {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : def;
}
const ROUNDS = Number(argVal('--rounds', '1'));
const SELF_PORT = 3998;
const BASE = argVal('--url', `http://localhost:${SELF_PORT}`);
const TIMEOUT_MS = Number(argVal('--timeout', '60000'));

// 与后端 llm_gateway.ts 同规则的法语判定（规则变化需两处同步）
const FRENCH_CHARS = /[éèêëàçùûôîïœ«»]/i;
const FRENCH_WORDS =
  /\b(je|tu|vous|nous|il|elle|on|est|suis|es|pas|ne|une|des|du|de|le|la|les|un|dans|pour|avec|bonjour|salut|merci|pardon|comprends|voilà|très|bien|oui|non|café|quoi|comment|pourquoi|d'accord|au revoir|bonne)\b/i;
const FORBIDDEN = ['Error:', 'ECONNREFUSED', 'at Object.', 'stack', 'undefined is not'];

const NPC_INFO = {
  name: 'Marie',
  job: '咖啡馆服务员',
  personality: '热情但忙碌',
  speaks_french: true,
};
const WORLD = { time_of_day: 'day', player_position: { x: 0, y: 0, z: 0 } };

// 10 个固定场景（各 ROUNDS 轮，每轮 2 句连续对话，验证历史契约）
const SCENARIOS = [
  { label: '问候', turns: ['bonjour', 'comment allez-vous?'] },
  { label: '点单', turns: ['un café, s’il vous plaît', 'et un croissant avec'] },
  { label: '询问推荐', turns: ['qu’est-ce que vous recommandez?', 'd’accord, très bien'] },
  { label: '询问工作', turns: ['vous travaillez ici depuis quand?', 'intéressant, merci'] },
  { label: '天气', turns: ['il fait beau aujourd’hui, non?', 'oui, on va marcher après'] },
  { label: '告别', turns: ['au revoir, bonne journée!', 'à demain alors'] },
  { label: '方向', turns: ['où est la gare, s’il vous plaît?', 'à pied, c’est loin?'] },
  { label: '道谢', turns: ['merci beaucoup pour votre aide', 'de rien, c’est normal'] },
  { label: '中文输入降级', turns: ['谢谢，请给我一杯咖啡', '好的，麻烦了'], expectFrench: true },
  { label: '闲聊', turns: ['vous aimez le football?', 'moi aussi, c’est passionnant'] },
];

function looksFrench(t) {
  return FRENCH_CHARS.test(t) || FRENCH_WORDS.test(t);
}

async function postDialog(input, history) {
  const started = Date.now();
  const res = await fetch(`${BASE}/api/dialog`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      player_input: input,
      npc_info: NPC_INFO,
      conversation_history: history,
      world_state: WORLD,
    }),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  const body = await res.json().catch(() => ({}));
  return { ms: Date.now() - started, status: res.status, body };
}

function percentile(sorted, p) {
  if (sorted.length === 0) return null;
  const idx = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, idx)];
}

async function ensureBackend() {
  try {
    const r = await fetch('http://localhost:3998/api/health', { signal: AbortSignal.timeout(1500) });
    if (r.ok) return { child: null, health: await r.json() };
  } catch {
    /* 需要自建 */
  }
  const dist = path.join(ROOT, 'backend/dist/server.js');
  if (!fs.existsSync(dist)) {
    const tsc = path.join(ROOT, 'backend/node_modules/.bin/tsc');
    if (!fs.existsSync(tsc)) return null;
    const b = spawnSync(tsc, [], { cwd: path.join(ROOT, 'backend'), encoding: 'utf8' });
    if (b.status !== 0) return null;
  }
  const child = spawn('node', [dist], {
    cwd: path.join(ROOT, 'backend'),
    env: { ...process.env, PORT: String(SELF_PORT) },
    stdio: 'ignore',
  });
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 250));
    try {
      const r = await fetch(`http://localhost:${SELF_PORT}/api/health`, { signal: AbortSignal.timeout(1000) });
      if (r.ok) return { child, health: await r.json() };
    } catch {
      /* 重试 */
    }
  }
  child.kill();
  return null;
}

async function main() {
  const report = {
    tool: 'dialog_regression',
    generated_at: new Date().toISOString(),
    rounds: ROUNDS,
    ok: false,
    status: 'running',
    scope:
      '固定法语脚本对真实后端+Ollama 的延迟与输出契约；不覆盖 NPC 人设一致性的人工评分、画面与真机帧率',
  };
  const outPath = path.join(ROOT, 'artifacts/dialog-regression-report.json');
  const finish = (code) => {
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, JSON.stringify(report, null, 2) + '\n');
    console.log(`报告: ${outPath}`);
    process.exit(code);
  };

  // 1) Ollama 可达性：不可达 → 明确 SKIP，不伪装通过
  try {
    await fetch('http://localhost:11434/api/tags', { signal: AbortSignal.timeout(2000) });
  } catch {
    report.status = 'skipped';
    report.skip_reason = 'Ollama 不可达（localhost:11434）';
    console.log('SKIP: Ollama 不可达，跳过对话回归');
    return finish(77);
  }

  // 2) 后端
  const backend = await ensureBackend();
  if (!backend) {
    report.status = 'skipped';
    report.skip_reason = '后端无法启动（dist 缺失且 tsc 不可用）';
    console.log('SKIP: 后端无法启动');
    return finish(77);
  }
  report.provider = backend.health?.provider ?? 'unknown';
  const ownChild = backend.child;

  const latencies = [];
  const failures = [];
  let calls = 0;
  let passed = 0;

  try {
    for (let round = 0; round < ROUNDS; round++) {
      for (const sc of SCENARIOS) {
        let history = [];
        for (const turn of sc.turns) {
          calls += 1;
          try {
            const { ms, status, body } = await postDialog(turn, history);
            latencies.push(ms);
            const errs = [];
            if (status !== 200) errs.push(`HTTP ${status} ${body.code ?? ''}`);
            const text = typeof body.text === 'string' ? body.text : '';
            if (!text.trim()) errs.push('空回复');
            else if (text.length > 2000) errs.push(`超长 ${text.length}`);
            else if (!looksFrench(text)) errs.push('无法语特征');
            else if (FORBIDDEN.some((f) => text.includes(f))) errs.push('泄漏底层错误');
            if (errs.length === 0) {
              passed += 1;
              history = [
                ...history,
                { role: 'player', content: turn },
                { role: 'assistant', content: text },
              ].slice(-10);
            } else {
              failures.push({ round: round + 1, scenario: sc.label, input: turn, errors: errs });
            }
          } catch (e) {
            failures.push({ round: round + 1, scenario: sc.label, input: turn, errors: [`请求异常: ${e.name}`] });
          }
        }
      }
    }
  } finally {
    if (ownChild) ownChild.kill();
  }

  const sorted = [...latencies].sort((a, b) => a - b);
  const passRate = calls ? passed / calls : 0;
  report.status = 'ran';
  report.calls = calls;
  report.passed = passed;
  report.pass_rate = Number(passRate.toFixed(4));
  report.latency_ms = {
    p50: percentile(sorted, 50),
    p95: percentile(sorted, 95),
    max: sorted.length ? sorted[sorted.length - 1] : null,
    note: '本地 Ollama 无首 token 流式接线，为端到端总耗时；首字延迟待接流式后另行度量',
  };
  report.failures = failures;
  report.ok = failures.length === 0 && passRate >= 0.95;

  console.log(
    `dialog_regression: ${passed}/${calls} 通过, p50=${report.latency_ms.p50}ms p95=${report.latency_ms.p95}ms max=${report.latency_ms.max}ms`,
  );
  for (const f of failures.slice(0, 10)) {
    console.log(`  FAIL [${f.scenario}] "${f.input}": ${f.errors.join('; ')}`);
  }
  return finish(report.ok ? 0 : 1);
}

main().catch((e) => {
  console.error('dialog_regression 异常:', e);
  process.exit(1);
});

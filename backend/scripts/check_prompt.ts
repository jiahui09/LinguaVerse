/**
 * Prompt 组装回归检查（无 LLM、离线可跑）
 * 断言：同一句玩家输入在 messages 中只出现一次；system 在最前；当前句在最后。
 * 用法：pnpm test  （tools/verify.sh 会调用）
 */

import { buildPrompt } from '../src/services/prompt_builder.js';

let failures = 0;

function check(cond: boolean, label: string): void {
  if (cond) {
    console.log(`PASS: ${label}`);
  } else {
    failures += 1;
    console.error(`FAIL: ${label}`);
  }
}

const npc_info = { name: 'Marie', job: '咖啡馆服务员', personality: '热情但忙碌', speaks_french: true };
const world_state = { time_of_day: 'day', player_position: { x: 0, y: 0, z: 0 } };

// 场景 1：契约正确 —— history 不含当前句
{
  const messages = JSON.parse(
    buildPrompt({
      player_input: 'un café, s’il vous plaît',
      npc_info,
      conversation_history: [
        { role: 'assistant', content: 'Bonjour! Vous désirez?' },
        { role: 'player', content: 'bonjour' },
        { role: 'assistant', content: 'Bonjour monsieur!' },
      ],
      world_state,
    }),
  );
  const current = 'un café, s’il vous plaît';
  const hits = messages.filter((m: { content: string }) => m.content === current);
  check(hits.length === 1, '当前句只出现一次');
  check(messages[0].role === 'system', 'system 位于首位');
  check(messages[messages.length - 1].role === 'user', '当前句位于末位');
}

// 场景 2：兜底 —— 旧客户端把当前句也塞进了历史（重复 bug 复现）
{
  const current = 'bonjour';
  const messages = JSON.parse(
    buildPrompt({
      player_input: current,
      npc_info,
      conversation_history: [
        { role: 'assistant', content: 'Bonjour! Vous désirez?' },
        { role: 'player', content: current },
      ],
      world_state,
    }),
  );
  const hits = messages.filter((m: { content: string }) => m.content === current);
  check(hits.length === 1, '历史中重复的当前句被去重（兜底）');
}

// 场景 3：连续两轮历史无重复 user
{
  const messages = JSON.parse(
    buildPrompt({
      player_input: 'noir, merci',
      npc_info,
      conversation_history: [
        { role: 'assistant', content: 'Bonjour! Vous désirez?' },
        { role: 'player', content: 'un café' },
        { role: 'assistant', content: 'Café crème ou noir?' },
      ],
      world_state,
    }),
  );
  const contents = messages.map((m: { content: string }) => m.content);
  const dup = contents.some((c: string, i: number) => i > 0 && c === contents[i - 1] && messages[i].role === 'user' && messages[i - 1].role === 'user');
  check(!dup, '无相邻重复 user 消息');
}

if (failures > 0) {
  console.error(`\n${failures} 项失败`);
  process.exit(1);
}
console.log('\n全部通过');

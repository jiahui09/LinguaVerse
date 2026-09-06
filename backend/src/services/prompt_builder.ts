/**
 * Prompt 组装器
 * 将 NPC 身份、世界状态、对话历史组装成 LLM 可理解的 Prompt
 */

interface PromptInput {
  player_input: string;
  npc_info: {
    name: string;
    job: string;
    personality: string;
    speaks_french: boolean;
  };
  conversation_history: Array<{ role: string; content: string }>;
  world_state: {
    time_of_day: string;
    player_position: { x: number; y: number; z: number };
  };
}

/**
 * 时间段中文映射
 */
const TIME_LABELS: Record<string, string> = {
  dawn: '清晨',
  day: '白天',
  dusk: '傍晚',
  night: '深夜',
};

/**
 * 组装系统 Prompt
 */
function buildSystemPrompt(input: PromptInput): string {
  const { npc_info, world_state } = input;
  const time_label = TIME_LABELS[world_state.time_of_day] || '白天';

  return `你是 ${npc_info.name}，一个巴黎 ${npc_info.job}。
你的性格是 ${npc_info.personality}。
你现在在工作，当前时间是${time_label}。
你会说法语，但不会英语或其他语言。玩家用其他语言说话时，你听不懂。

玩家是一个刚搬到巴黎的新居民，法语不太好。

说话要求：
- 自然、口语化，像真实的巴黎人
- 根据玩家的表达水平调整复杂度（对初学者用简单句）
- 如果听不懂就说 "Je ne comprends pas" 或 "Pardon?"
- 不要主动教语法，你只是在过自己的生活
- 回应要简短自然，像真实对话（1-3 句话）
- 如果对话自然结束，就说 "Bonne journée!" 或 "Au revoir!"`;
}

/**
 * 组装完整 Prompt（发送给 LLM）
 */
export function buildPrompt(input: PromptInput): string {
  const systemPrompt = buildSystemPrompt(input);

  // 构建对话历史
  const messages: Array<{ role: string; content: string }> = [
    { role: 'system', content: systemPrompt },
  ];

  // 添加历史对话（最多保留最近 10 轮）
  const recentHistory = input.conversation_history.slice(-10);
  for (const msg of recentHistory) {
    messages.push({
      role: msg.role === 'player' ? 'user' : 'assistant',
      content: msg.content,
    });
  }

  // 添加当前玩家输入
  messages.push({ role: 'user', content: input.player_input });

  return JSON.stringify(messages);
}

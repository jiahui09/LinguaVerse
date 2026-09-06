import type { FastifyInstance } from 'fastify';
import { buildPrompt } from '../services/prompt_builder.js';
import { getLLMAdapter } from '../services/llm_gateway.js';

interface DialogRequest {
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

export async function dialogRoutes(app: FastifyInstance) {
  // 普通对话请求（非流式）
  app.post<{ Body: DialogRequest }>('/api/dialog', async (request, reply) => {
    const { player_input, npc_info, conversation_history, world_state } = request.body;

    if (!player_input || !npc_info) {
      return reply.status(400).send({ error: '缺少 player_input 或 npc_info' });
    }

    const prompt = buildPrompt({ player_input, npc_info, conversation_history, world_state });
    const adapter = getLLMAdapter();

    try {
      const response = await adapter.chat(prompt);
      return { text: response, npc_name: npc_info.name };
    } catch (err) {
      app.log.error(err);
      return reply.status(500).send({ error: 'LLM 请求失败' });
    }
  });

  // 流式对话请求（SSE）
  app.post<{ Body: DialogRequest }>('/api/dialog/stream', async (request, reply) => {
    const { player_input, npc_info, conversation_history, world_state } = request.body;

    if (!player_input || !npc_info) {
      return reply.status(400).send({ error: '缺少 player_input 或 npc_info' });
    }

    const prompt = buildPrompt({ player_input, npc_info, conversation_history, world_state });
    const adapter = getLLMAdapter();

    reply.raw.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
    });

    try {
      for await (const chunk of adapter.chatStream(prompt)) {
        reply.raw.write(`data: ${JSON.stringify({ text: chunk, done: false })}\n\n`);
      }
      reply.raw.write(`data: ${JSON.stringify({ text: '', done: true })}\n\n`);
    } catch (err) {
      app.log.error(err);
      reply.raw.write(`data: ${JSON.stringify({ error: 'LLM 流式请求失败', done: true })}\n\n`);
    }

    reply.raw.end();
  });
}

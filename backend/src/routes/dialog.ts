import type { FastifyInstance } from 'fastify';
import { buildPrompt } from '../services/prompt_builder.js';
import { GatewayError, assertModelAllowed, getLLMAdapter, guardedChat } from '../services/llm_gateway.js';

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

/** 网关错误 → HTTP 状态（code 是唯一对外契约，message 只进日志） */
const STATUS_BY_CODE: Record<string, number> = {
  LLM_TIMEOUT: 504,
  LLM_MODEL_INVALID: 500,
  LLM_UNAVAILABLE: 500,
  LLM_BAD_OUTPUT: 200,
};

export async function dialogRoutes(app: FastifyInstance) {
  // 普通对话请求（非流式）
  app.post<{ Body: DialogRequest }>('/api/dialog', async (request, reply) => {
    const { player_input, npc_info, conversation_history, world_state } = request.body;

    if (!player_input || !npc_info) {
      return reply.status(400).send({ error: '缺少 player_input 或 npc_info' });
    }

    const prompt = buildPrompt({ player_input, npc_info, conversation_history, world_state });

    try {
      const { text, code } = await guardedChat(prompt);
      const body: { text: string; npc_name: string; code?: string } = {
        text,
        npc_name: npc_info.name,
      };
      if (code) body.code = code;
      return body;
    } catch (err) {
      if (err instanceof GatewayError) {
        app.log.error({ code: err.code, msg: err.message }, 'dialog failed');
        return reply.status(STATUS_BY_CODE[err.code] ?? 500).send({ code: err.code });
      }
      app.log.error(err);
      return reply.status(500).send({ code: 'LLM_UNAVAILABLE' });
    }
  });

  // 流式对话请求（SSE）
  app.post<{ Body: DialogRequest }>('/api/dialog/stream', async (request, reply) => {
    const { player_input, npc_info, conversation_history, world_state } = request.body;

    if (!player_input || !npc_info) {
      return reply.status(400).send({ error: '缺少 player_input 或 npc_info' });
    }

    try {
      assertModelAllowed();
    } catch (err) {
      const code = err instanceof GatewayError ? err.code : 'LLM_MODEL_INVALID';
      return reply.status(500).send({ code });
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
      const code = err instanceof GatewayError ? err.code : 'LLM_UNAVAILABLE';
      reply.raw.write(`data: ${JSON.stringify({ code, done: true })}\n\n`);
    }

    reply.raw.end();
  });
}

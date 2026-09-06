import 'dotenv/config';
import Fastify from 'fastify';
import cors from '@fastify/cors';
import { dialogRoutes } from './routes/dialog.js';

const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '0.0.0.0';

const app = Fastify({
  logger: {
    level: 'info',
    transport: {
      target: 'pino-pretty',
      options: { colorize: true },
    },
  },
});

// CORS — 开发阶段允许所有来源
await app.register(cors, {
  origin: true,
  methods: ['GET', 'POST'],
  allowedHeaders: ['Content-Type'],
});

// 健康检查
app.get('/api/health', async () => {
  return { status: 'ok', provider: process.env.LLM_PROVIDER || 'ollama' };
});

// 对话路由
await app.register(dialogRoutes);

// 启动服务
try {
  await app.listen({ port: PORT, host: HOST });
  app.log.info(`语宙 AI 网关运行在 http://${HOST}:${PORT}`);
  app.log.info(`LLM 适配器: ${process.env.LLM_PROVIDER || 'ollama'}`);
} catch (err) {
  app.log.error(err);
  process.exit(1);
}

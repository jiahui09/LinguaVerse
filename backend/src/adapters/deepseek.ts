/**
 * DeepSeek 适配器（生产环境，性价比最高）
 * API 兼容 OpenAI 格式
 */

import type { LLMAdapter } from '../services/llm_gateway.js';

const BASE_URL = 'https://api.deepseek.com';
const API_KEY = process.env.DEEPSEEK_API_KEY || '';
const MODEL = process.env.DEEPSEEK_MODEL || 'deepseek-chat';

export class DeepSeekAdapter implements LLMAdapter {
  async chat(messagesJson: string): Promise<string> {
    if (!API_KEY) throw new Error('DEEPSEEK_API_KEY 未配置');

    const messages = JSON.parse(messagesJson);

    const response = await fetch(`${BASE_URL}/v1/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${API_KEY}`,
      },
      body: JSON.stringify({
        model: MODEL,
        messages,
        stream: false,
      }),
    });

    if (!response.ok) {
      throw new Error(`DeepSeek 请求失败: ${response.status}`);
    }

    const data = await response.json();
    return data.choices?.[0]?.message?.content || '';
  }

  async *chatStream(messagesJson: string): AsyncGenerator<string> {
    if (!API_KEY) throw new Error('DEEPSEEK_API_KEY 未配置');

    const messages = JSON.parse(messagesJson);

    const response = await fetch(`${BASE_URL}/v1/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${API_KEY}`,
      },
      body: JSON.stringify({
        model: MODEL,
        messages,
        stream: true,
      }),
    });

    if (!response.ok) {
      throw new Error(`DeepSeek 流式请求失败: ${response.status}`);
    }

    const reader = response.body?.getReader();
    if (!reader) throw new Error('无法获取响应流');

    const decoder = new TextDecoder();
    let buffer = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop() || '';

      for (const line of lines) {
        if (!line.startsWith('data: ')) continue;
        const data = line.slice(6);
        if (data === '[DONE]') return;
        try {
          const parsed = JSON.parse(data);
          const content = parsed.choices?.[0]?.delta?.content;
          if (content) yield content;
        } catch {
          // 跳过无法解析的行
        }
      }
    }
  }
}

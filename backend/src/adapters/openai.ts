/**
 * OpenAI 适配器（备选）
 * GPT-4o-mini 性价比不错
 */

import type { LLMAdapter } from '../services/llm_gateway.js';

const API_KEY = process.env.OPENAI_API_KEY || '';
const MODEL = process.env.OPENAI_MODEL || 'gpt-4o-mini';

export class OpenAIAdapter implements LLMAdapter {
  async chat(messagesJson: string): Promise<string> {
    if (!API_KEY) throw new Error('OPENAI_API_KEY 未配置');

    const messages = JSON.parse(messagesJson);

    const response = await fetch('https://api.openai.com/v1/chat/completions', {
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
      throw new Error(`OpenAI 请求失败: ${response.status}`);
    }

    const data = await response.json();
    return data.choices?.[0]?.message?.content || '';
  }

  async *chatStream(messagesJson: string): AsyncGenerator<string> {
    if (!API_KEY) throw new Error('OPENAI_API_KEY 未配置');

    const messages = JSON.parse(messagesJson);

    const response = await fetch('https://api.openai.com/v1/chat/completions', {
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
      throw new Error(`OpenAI 流式请求失败: ${response.status}`);
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

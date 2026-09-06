/**
 * Ollama 适配器（本地开发用）
 * 零成本、快速迭代
 */

import type { LLMAdapter } from '../services/llm_gateway.js';

const BASE_URL = process.env.OLLAMA_BASE_URL || 'http://localhost:11434';
const MODEL = process.env.OLLAMA_MODEL || 'qwen2.5:7b';

export class OllamaAdapter implements LLMAdapter {
  async chat(messagesJson: string): Promise<string> {
    const messages = JSON.parse(messagesJson);

    const response = await fetch(`${BASE_URL}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: MODEL,
        messages,
        stream: false,
      }),
    });

    if (!response.ok) {
      throw new Error(`Ollama 请求失败: ${response.status} ${response.statusText}`);
    }

    const data = await response.json();
    return data.message?.content || '';
  }

  async *chatStream(messagesJson: string): AsyncGenerator<string> {
    const messages = JSON.parse(messagesJson);

    const response = await fetch(`${BASE_URL}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: MODEL,
        messages,
        stream: true,
      }),
    });

    if (!response.ok) {
      throw new Error(`Ollama 流式请求失败: ${response.status}`);
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
        if (!line.trim()) continue;
        try {
          const chunk = JSON.parse(line);
          if (chunk.message?.content) {
            yield chunk.message.content;
          }
        } catch {
          // 跳过无法解析的行
        }
      }
    }
  }
}

/**
 * LLM 统一网关
 * 适配器模式 — 切换 LLM 供应商只改配置，不改代码
 */

import { OllamaAdapter } from '../adapters/ollama.js';
import { DeepSeekAdapter } from '../adapters/deepseek.js';
import { OpenAIAdapter } from '../adapters/openai.js';

export interface LLMAdapter {
  /** 单次对话（非流式） */
  chat(messagesJson: string): Promise<string>;
  /** 流式对话，逐 chunk 返回文本 */
  chatStream(messagesJson: string): AsyncGenerator<string>;
}

let cachedAdapter: LLMAdapter | null = null;

/**
 * 获取当前配置的 LLM 适配器（单例）
 */
export function getLLMAdapter(): LLMAdapter {
  if (cachedAdapter) return cachedAdapter;

  const provider = (process.env.LLM_PROVIDER || 'ollama').toLowerCase();

  switch (provider) {
    case 'ollama':
      cachedAdapter = new OllamaAdapter();
      break;
    case 'deepseek':
      cachedAdapter = new DeepSeekAdapter();
      break;
    case 'openai':
      cachedAdapter = new OpenAIAdapter();
      break;
    default:
      throw new Error(`未知的 LLM 适配器: ${provider}。支持: ollama, deepseek, openai`);
  }

  return cachedAdapter;
}

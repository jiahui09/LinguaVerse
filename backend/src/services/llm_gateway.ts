/**
 * LLM 统一网关
 * 适配器模式 — 切换 LLM 供应商只改配置，不改代码
 *
 * 护栏（P0-A5/A6）：
 * - 模型必须是 instruct/chat 模型，-base 模型直接拒绝
 * - 单轮请求超时保护，超时不重试（避免玩家等两倍时间）
 * - 输出做非空/长度/法语特征校验，失败重试一次后降级返回安抚话术
 * - 所有失败以稳定 code 上抛，由路由映射，禁止把底层错误透传给玩家
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

/** 带稳定 code 的网关错误（code 才是接口契约，message 只供日志） */
export class GatewayError extends Error {
  constructor(
    public readonly code: 'LLM_TIMEOUT' | 'LLM_UNAVAILABLE' | 'LLM_MODEL_INVALID' | 'LLM_BAD_OUTPUT',
    message: string,
  ) {
    super(message);
    this.name = 'GatewayError';
  }
}

const REQUEST_TIMEOUT_MS = Number(process.env.LLM_TIMEOUT_MS || 30_000);
const MAX_OUTPUT_CHARS = 2000;
const DEGRADED_TEXT = 'Pardon? Je ne comprends pas très bien.';

let cachedAdapter: LLMAdapter | null = null;

/** 当前配置对应的模型名 */
function currentModel(provider: string): string {
  switch (provider) {
    case 'ollama':
      return process.env.OLLAMA_MODEL || 'qwen2.5:7b';
    case 'deepseek':
      return process.env.DEEPSEEK_MODEL || 'deepseek-chat';
    case 'openai':
      return process.env.OPENAI_MODEL || 'gpt-4o-mini';
    default:
      return '';
  }
}

/**
 * 模型护栏：拒绝非 instruct 的 base 模型（实测 base 模型会返回教程类垃圾文本）
 * 在启动时与每次请求前调用。
 */
export function assertModelAllowed(): void {
  const provider = (process.env.LLM_PROVIDER || 'ollama').toLowerCase();
  if (provider !== 'ollama' && provider !== 'deepseek' && provider !== 'openai') {
    throw new GatewayError('LLM_MODEL_INVALID', `未知的 LLM 适配器: ${provider}。支持: ollama, deepseek, openai`);
  }
  const model = currentModel(provider);
  if (/base/i.test(model)) {
    throw new GatewayError('LLM_MODEL_INVALID', `模型 ${model} 看起来是 base 模型，必须使用 instruct/chat 模型`);
  }
}

/**
 * 获取当前配置的 LLM 适配器（单例）
 */
export function getLLMAdapter(): LLMAdapter {
  if (cachedAdapter) return cachedAdapter;

  assertModelAllowed();
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
      throw new GatewayError('LLM_MODEL_INVALID', `未知的 LLM 适配器: ${provider}`);
  }

  return cachedAdapter;
}

/** 法语特征：变音符号 + 高频法语词（NPC 只会说法语，决策 4） */
const FRENCH_CHARS = /[éèêëàçùûôîïœ«»]/i;
const FRENCH_WORDS =
  /\b(je|tu|vous|nous|il|elle|on|est|suis|es|pas|ne|une|des|du|de|le|la|les|un|dans|pour|avec|bonjour|salut|merci|pardon|comprends|voilà|très|bien|oui|non|café|quoi|comment|pourquoi|d'accord|au revoir|bonne)\b/i;

export function looksLikeFrench(text: string): boolean {
  return FRENCH_CHARS.test(text) || FRENCH_WORDS.test(text);
}

/** 输出校验：非空 + 长度上限 + 法语特征 */
export function validateOutput(text: string): boolean {
  const t = text.trim();
  if (!t || t.length > MAX_OUTPUT_CHARS) return false;
  return looksLikeFrench(t);
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new GatewayError('LLM_TIMEOUT', `LLM 请求超时 ${ms}ms`)), ms);
    promise.then(
      (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      (e) => {
        clearTimeout(timer);
        reject(e);
      },
    );
  });
}

/**
 * 带护栏的单轮对话。
 * 成功：{ text }；输出不合格但已重试：{ text: 降级话术, code: 'LLM_BAD_OUTPUT' }。
 * 其余失败抛 GatewayError。
 */
export async function guardedChat(messagesJson: string): Promise<{ text: string; code?: 'LLM_BAD_OUTPUT' }> {
  assertModelAllowed();
  const adapter = getLLMAdapter();

  let lastUnknownError: unknown = null;

  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const raw = await withTimeout(adapter.chat(messagesJson), REQUEST_TIMEOUT_MS);
      if (validateOutput(raw)) {
        return { text: raw.trim() };
      }
      lastUnknownError = new GatewayError('LLM_BAD_OUTPUT', `输出未通过法语/格式校验（长度 ${raw.trim().length}）`);
    } catch (err) {
      // 超时不重试：再等一轮只会让玩家等两倍时间
      if (err instanceof GatewayError && err.code === 'LLM_TIMEOUT') throw err;
      lastUnknownError = err;
    }
  }

  if (lastUnknownError instanceof GatewayError && lastUnknownError.code === 'LLM_BAD_OUTPUT') {
    return { text: DEGRADED_TEXT, code: 'LLM_BAD_OUTPUT' };
  }
  if (lastUnknownError instanceof GatewayError) throw lastUnknownError;
  throw new GatewayError('LLM_UNAVAILABLE', lastUnknownError instanceof Error ? lastUnknownError.message : 'LLM 请求失败');
}

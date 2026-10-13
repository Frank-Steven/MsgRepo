import type { Config } from "../config.js";
import type { AIProvider } from "./provider.js";
import { MockProvider } from "./mock.js";
import { OllamaProvider } from "./ollama.js";
import { OpenAICompatProvider } from "./openai-compat.js";

/** 按配置创建 AI provider；CLI（index.ts）与 Electron 主进程共用。 */
export function createProvider(cfg: Config): AIProvider {
  switch (cfg.provider) {
    case "ollama":
      return new OllamaProvider(cfg.ollama);
    case "openai-compatible":
      return new OpenAICompatProvider({
        ...cfg.openai,
        apiKey: process.env[cfg.openai.apiKeyEnv],
      });
    default:
      return new MockProvider();
  }
}

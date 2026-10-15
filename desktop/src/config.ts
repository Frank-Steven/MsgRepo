import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { DESKTOP_ROOT } from "./registry.js";

export interface Config {
  host: string;
  port: number;
  provider: string;
  ollama: { baseUrl: string; model: string };
  openai: { baseUrl: string; model: string; apiKeyEnv: string };
}

/** 加载 config/default.json，并用 config/local.json（git 忽略）做浅合并覆盖。
 *  extraOverridePaths 为可选的追加覆盖文件（如托盘应用的 userData/config.json），按顺序最后应用。 */
export function loadConfig(extraOverridePaths: string[] = []): Config {
  const cfg = JSON.parse(
    readFileSync(path.join(DESKTOP_ROOT, "config/default.json"), "utf8"),
  ) as Config;
  const localPath = path.join(DESKTOP_ROOT, "config/local.json");
  for (const overridePath of [localPath, ...extraOverridePaths]) {
    if (!existsSync(overridePath)) continue;
    const override = JSON.parse(readFileSync(overridePath, "utf8")) as Record<string, unknown>;
    for (const [k, v] of Object.entries(override)) {
      if (v && typeof v === "object" && !Array.isArray(v) && typeof cfg[k as keyof Config] === "object") {
        Object.assign(cfg[k as keyof Config] as object, v);
      } else {
        (cfg as unknown as Record<string, unknown>)[k] = v;
      }
    }
  }
  return cfg;
}

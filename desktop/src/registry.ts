import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv2020 } from "ajv/dist/2020.js";
import type { CategoryRegistry, SyncRequest } from "./types.js";

const here = path.dirname(fileURLToPath(import.meta.url));
// src/ 与编译产物 dist/ 的上一级都是 desktop/
export const DESKTOP_ROOT = path.resolve(here, "..");
export const SHARED_DIR = path.resolve(DESKTOP_ROOT, "..", "shared");

export function readSharedJson(rel: string): unknown {
  return JSON.parse(readFileSync(path.join(SHARED_DIR, rel), "utf8"));
}

export function loadDefaultRegistry(): CategoryRegistry {
  return readSharedJson("registry/default.json") as CategoryRegistry;
}

/** 加载当前生效注册表：优先 data/registry.json（协商落盘），否则 shared 默认。 */
export function loadRegistry(dataDir: string): CategoryRegistry {
  const negotiated = path.join(dataDir, "registry.json");
  if (existsSync(negotiated)) {
    try {
      return JSON.parse(readFileSync(negotiated, "utf8")) as CategoryRegistry;
    } catch {
      // 损坏则回退默认
    }
  }
  return loadDefaultRegistry();
}

export function validateRegistry(registry: unknown): registry is CategoryRegistry {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  const schema = readSharedJson("schemas/category-registry.schema.json") as object;
  return ajv.validate(schema, registry);
}

/**
 * 版本协商：请求携带 registry 且版本与本地不同时，
 * 校验通过后采用请求中的注册表并落盘 data/registry.json。
 */
export function negotiateRegistry(
  req: SyncRequest,
  current: CategoryRegistry,
  dataDir: string,
): { registry: CategoryRegistry; warnings: string[] } {
  const warnings: string[] = [];
  let registry = current;
  if (req.registry && req.registry.version !== current.version) {
    const incoming: unknown = req.registry;
    if (validateRegistry(incoming)) {
      registry = incoming;
      writeFileSync(path.join(dataDir, "registry.json"), JSON.stringify(registry, null, 2));
      warnings.push(
        `注册表版本不一致（手机 v${registry.version} / 电脑 v${current.version}），已采用手机端注册表并落盘`,
      );
    } else {
      warnings.push(
        `请求携带的注册表 v${req.registry.version} 未通过 schema 校验，沿用电脑端 v${current.version}`,
      );
    }
  }
  return { registry, warnings };
}

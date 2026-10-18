import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { buildEvalBatchSystemPrompt } from "./evaluate.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const registryPath = path.resolve(here, "../../../shared/registry/default.json");
const registry = JSON.parse(readFileSync(registryPath, "utf8")) as {
  categories: Array<{ key: string; priorityHints?: string; payloadSchema?: unknown }>;
  definitions?: unknown;
};

// 提示词词汇一致性（2026-10-18）：分类提示统一为 red/yellow/green/junk，
// 与输出 schema 的 priority 取值一致；v1 的 P0-P3 只保留在 defaultPriority 字段。
test("registry priorityHints 不再使用 P0-P3", () => {
  for (const c of registry.categories) {
    const hint = c.priorityHints ?? "";
    assert.ok(
      !/P[0-3]/.test(hint),
      `${c.key} 的提示仍在用 v1 词汇：${hint}`,
    );
  }
});

test("批量系统提示词里出现的分类提示已统一词汇", () => {
  const prompt = buildEvalBatchSystemPrompt(
    registry as never,
    undefined,
  );
  const categorySection = prompt.slice(prompt.indexOf("分类参考"));
  assert.ok(!/P[0-3]/.test(categorySection), "提示词的分类段不应出现 P0-P3");
  assert.ok(categorySection.includes("junk"), "营销类应指向 junk");
});

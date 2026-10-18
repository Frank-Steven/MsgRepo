import assert from "node:assert/strict";
import { test } from "node:test";

import { processStreaming, shouldRetryPerMessage } from "./pipeline.js";
import type { AIProvider } from "./ai/provider.js";
import type { CategoryRegistry, EvalResult, ProcessInputMessage, ProcessEvent } from "./types.js";

/// P1-2 回归：批量评估整批失败时，必须降级为逐条重试而不是整批报错。
const registry = { version: 1, categories: [], definitions: {} } as unknown as CategoryRegistry;

function msg(id: string): ProcessInputMessage {
  return { id, title: `测试消息 ${id}`, body: "下班前交周报", postedAt: 1_700_000_000_000 };
}

function fakeProvider(opts: {
  batchFails: boolean;
  singleFails?: boolean;
  counts?: { batch: number; single: number };
}): AIProvider {
  const ok = (id: string): EvalResult =>
    ({ priority: "yellow", reason: "待办", taskDraft: null }) as unknown as EvalResult;
  return {
    name: "fake",
    async process() {
      return [];
    },
    async evaluateBatchStreaming(batch) {
      if (opts.counts) opts.counts.batch++;
      if (opts.batchFails) throw new Error("模型未返回 JSON 数组");
      const m = new Map<string, EvalResult>();
      for (const b of batch) m.set(b.id, ok(b.id));
      return m;
    },
    async evaluateStreaming(single) {
      if (opts.counts) opts.counts.single++;
      if (opts.singleFails) throw new Error("单条也失败");
      return ok(single.id);
    },
  } as AIProvider;
}

async function run(provider: AIProvider, messages: ProcessInputMessage[]) {
  const events: ProcessEvent[] = [];
  const result = await processStreaming(messages, registry, provider, {
    now: 1_700_000_000_000,
    onEvent: (e) => events.push(e),
  });
  return { events, result };
}

test("整批失败 → 逐条重试，全部拿到结果", async () => {
  const counts = { batch: 0, single: 0 };
  const { events, result } = await run(
    fakeProvider({ batchFails: true, counts }),
    [msg("a"), msg("b"), msg("c")],
  );
  const results = events.filter((e) => e.type === "result");
  assert.equal(results.length, 3);
  assert.equal(events.filter((e) => e.type === "error").length, 0);
  assert.equal(result.failed, 0);
  assert.equal(counts.batch, 1, "只应尝试一次批量");
  assert.equal(counts.single, 3, "应对三条各重试一次");
});

test("整批失败且逐条也失败 → 每条都报错并计入 failed", async () => {
  const { events, result } = await run(
    fakeProvider({ batchFails: true, singleFails: true }),
    [msg("a"), msg("b")],
  );
  assert.equal(events.filter((e) => e.type === "error").length, 2);
  assert.equal(result.failed, 2);
});

test("批量正常时不做逐条重试", async () => {
  const counts = { batch: 0, single: 0 };
  const { events, result } = await run(
    fakeProvider({ batchFails: false, counts }),
    [msg("a"), msg("b")],
  );
  assert.equal(events.filter((e) => e.type === "result").length, 2);
  assert.equal(result.failed, 0);
  assert.equal(counts.single, 0, "不应触发逐条重试");
});

test("配置类错误（400 模型名）不逐条重发，避免 N 份全量提示词", async () => {
  const counts = { batch: 0, single: 0 };
  const provider = {
    name: "fake",
    async process() {
      return [];
    },
    async evaluateBatchStreaming() {
      counts.batch++;
      throw new Error(
        "远程接口返回 400：The supported API model names are deepseek-flash, deepseek-v4-pro",
      );
    },
    async evaluateStreaming() {
      counts.single++;
      return { priority: "green", reason: "x", taskDraft: null } as never;
    },
  } as unknown as AIProvider;
  const events: ProcessEvent[] = [];
  const result = await processStreaming([msg("a"), msg("b"), msg("c")], registry, provider, {
    now: 1_700_000_000_000,
    onEvent: (e) => events.push(e),
  });
  assert.equal(counts.batch, 1);
  assert.equal(counts.single, 0, "配置错误不应触发逐条重试");
  assert.equal(events.filter((e) => e.type === "error").length, 3);
  assert.equal(result.failed, 3);
});

test("shouldRetryPerMessage 只认模型输出问题", () => {
  assert.equal(shouldRetryPerMessage("模型未返回 JSON 数组：abc"), true);
  assert.equal(shouldRetryPerMessage("模型输出不是 JSON 数组: x"), true);
  assert.equal(shouldRetryPerMessage("模型未返回 JSON: x"), true);
  assert.equal(shouldRetryPerMessage("远程接口返回 401：bad key"), false);
  assert.equal(shouldRetryPerMessage("fetch failed"), false);
});

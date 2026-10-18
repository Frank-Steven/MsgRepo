import assert from "node:assert/strict";
import { test } from "node:test";

import { parseEvalBatchOutput } from "./evaluate.js";
import type { ProcessInputMessage } from "../../types.js";

// N1：一条消息可以产出多个任务草稿；旧的单个 taskDraft 仍兼容。
const batch: ProcessInputMessage[] = [
  { id: "m1", title: "课代表通知", body: "交作业、还有体检预约", postedAt: 1_700_000_000_000 },
];

test("taskDrafts 数组解析出多个草稿", () => {
  const out = parseEvalBatchOutput(
    batch,
    JSON.stringify([
      {
        messageId: "m1",
        priority: "red",
        reason: "两件事",
        taskDrafts: [
          { title: "交作业", kind: "point", priority: "important" },
          { title: "预约体检", kind: "point", priority: "normal" },
        ],
      },
    ]),
  );
  const r = out.get("m1");
  assert.ok(r);
  assert.equal(r.taskDrafts?.length, 2);
  assert.equal(r.taskDraft?.title, "交作业", "兼容字段取第一条");
  assert.equal(r.taskDrafts?.[1].title, "预约体检");
});

test("只有 taskDraft 时仍可用", () => {
  const out = parseEvalBatchOutput(
    batch,
    JSON.stringify([
      { messageId: "m1", priority: "green", taskDraft: { title: "单条", kind: "range" } },
    ]),
  );
  const r = out.get("m1");
  assert.equal(r?.taskDrafts?.length, 1);
  assert.equal(r?.taskDraft?.title, "单条");
});

test("超过 3 个时截断（提示词上限）", () => {
  const out = parseEvalBatchOutput(
    batch,
    JSON.stringify([
      {
        messageId: "m1",
        priority: "yellow",
        taskDrafts: [1, 2, 3, 4, 5].map((i) => ({ title: `任务${i}` })),
      },
    ]),
  );
  assert.equal(out.get("m1")?.taskDrafts?.length, 3);
});

import assert from "node:assert/strict";
import { test } from "node:test";

import { GateBusyError, SerialGate } from "./limit.js";

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

test("串行：并发峰值始终为 1", async () => {
  const gate = new SerialGate(1, 8);
  let active = 0;
  let peak = 0;
  const task = async () => {
    active++;
    peak = Math.max(peak, active);
    await sleep(10);
    active--;
  };
  await Promise.all([gate.run(task), gate.run(task), gate.run(task)]);
  assert.equal(peak, 1);
  assert.equal(gate.activeCount, 0);
});

test("maxConcurrent=2 时允许两个并行", async () => {
  const gate = new SerialGate(2, 8);
  let active = 0;
  let peak = 0;
  const task = async () => {
    active++;
    peak = Math.max(peak, active);
    await sleep(15);
    active--;
  };
  await Promise.all([gate.run(task), gate.run(task), gate.run(task), gate.run(task)]);
  assert.equal(peak, 2);
});

test("队列满 → GateBusyError（而不是无界排队）", async () => {
  const gate = new SerialGate(1, 1);
  const slow = () => sleep(50);
  const p1 = gate.run(slow);
  const p2 = gate.run(slow);
  await assert.rejects(
    () => gate.run(slow),
    (e: unknown) => e instanceof GateBusyError && e.code === "GATE_BUSY",
  );
  await Promise.all([p1, p2]);
  assert.equal(gate.activeCount, 0);
});

test("任务抛错也会释放槽位", async () => {
  const gate = new SerialGate(1, 1);
  await assert.rejects(() =>
    gate.run(async () => {
      throw new Error("boom");
    }),
  );
  assert.equal(await gate.run(async () => 42), 42);
});

test("acquireSlot 重复调用释放函数只释放一次", async () => {
  const gate = new SerialGate(1, 1);
  const release = await gate.acquireSlot();
  assert.equal(gate.activeCount, 1);
  release();
  release();
  assert.equal(gate.activeCount, 0);
});

import type { CategoryRegistry, RawMessage, StructuredItem, TimeInfo } from "../types.js";

/** AI 适配器接口：对一批原始消息做分类 + 抽取，产出结构化结果。 */
export interface AIProvider {
  readonly name: string;
  readonly model?: string;
  process(messages: RawMessage[], registry: CategoryRegistry): Promise<StructuredItem[]>;
}

/** 规整 AI 返回的 time 字段：非法/缺省时回退 { kind: "none" }。 */
export function normalizeTime(t: unknown): TimeInfo {
  if (!t || typeof t !== "object") return { kind: "none" };
  const o = t as Record<string, unknown>;
  const kinds = new Set(["none", "point", "range", "deadline", "recurring"]);
  if (typeof o.kind !== "string" || !kinds.has(o.kind)) return { kind: "none" };
  const time: TimeInfo = { kind: o.kind as TimeInfo["kind"] };
  for (const k of ["startAt", "endAt", "deadline"] as const) {
    if (typeof o[k] === "number") time[k] = o[k] as number;
  }
  if (typeof o.rrule === "string") time.rrule = o.rrule;
  if (Array.isArray(o.reminderOffsets)) {
    time.reminderOffsets = o.reminderOffsets.filter((n): n is number => typeof n === "number");
  }
  return time;
}

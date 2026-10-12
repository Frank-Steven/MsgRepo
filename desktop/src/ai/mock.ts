import { randomUUID } from "node:crypto";
import type { AIProvider, EvaluateOptions } from "./provider.js";
import {
  PIPELINE_VERSION,
  SCHEMA_VERSION,
  type CategoryRegistry,
  type EvalPriority,
  type EvalResult,
  type GenericField,
  type Priority,
  type ProcessInputMessage,
  type RawMessage,
  type StructuredItem,
  type TaskDraft,
  type TimeInfo,
} from "../types.js";

/**
 * 规则引擎 provider：关键词分类 + 正则抽取，不依赖任何模型也能端到端跑通。
 * 相对时间以消息 postedAt 为基准解析为绝对毫秒。
 */
export class MockProvider implements AIProvider {
  readonly name = "mock";

  async process(messages: RawMessage[], registry: CategoryRegistry): Promise<StructuredItem[]> {
    // 规则引擎无提示词概念，options.customPrompt 接受但忽略
    return messages.map((msg) => this.buildItem(msg, registry));
  }

  /** v2 流式评估的规则版：按关键词分类映射优先级，并模拟逐段 token 输出。 */
  async evaluateStreaming(
    message: ProcessInputMessage,
    _registry: CategoryRegistry,
    options: EvaluateOptions,
  ): Promise<EvalResult> {
    const text = `${message.title}\n${message.body}`;
    const category = classify(text);
    const timeMs = extractTimeMs(text, message.postedAt);

    const priority: EvalPriority =
      category === "coupon"
        ? "junk"
        : category === "verification"
          ? "red"
          : category === "generic"
            ? "green"
            : "yellow";
    let taskDraft: TaskDraft | null = null;
    if ((category === "schedule" || category === "todo") && timeMs) {
      const d = new Date(timeMs);
      const two = (n: number) => String(n).padStart(2, "0");
      taskDraft = {
        title: message.title || message.body.slice(0, 20),
        kind: "point",
        startAt: `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}T${two(d.getHours())}:${two(d.getMinutes())}`,
        priority: category === "schedule" ? "important" : "normal",
      };
    }
    const result: EvalResult = {
      priority,
      reason: `规则引擎命中分类 ${category}`,
      taskDraft,
    };
    // 模拟流式：把结果 JSON 分段回调，便于无模型时验证 token 透传链路
    const raw = JSON.stringify(result);
    for (let i = 0; i < raw.length; i += 16) {
      options.onToken?.(raw.slice(i, i + 16));
      await new Promise((r) => setImmediate(r));
    }
    return result;
  }

  private buildItem(msg: RawMessage, registry: CategoryRegistry): StructuredItem {
    const text = `${msg.title}\n${msg.body}`;
    const category = classify(text);
    const catDef = registry.categories.find((c) => c.key === category);
    const timeMs = extractTimeMs(text, msg.postedAt);

    let payload: Record<string, unknown>;
    let time: TimeInfo = { kind: "none" };
    let priority: Priority = catDef?.defaultPriority ?? "P2";
    let title = msg.title || msg.body.slice(0, 20);
    const source = msg.source.appName ?? msg.source.packageName;

    switch (category) {
      case "verification": {
        const code = extractVerificationCode(text);
        const fields: GenericField[] = [];
        if (code) fields.push({ key: "验证码", value: code, valueType: "string" });
        if (timeMs) fields.push({ key: "有效期至", value: String(timeMs), valueType: "datetime" });
        fields.push({ key: "来源", value: source, valueType: "string" });
        payload = { fields };
        priority = "P0"; // 验证码收到即 P0
        if (timeMs) time = { kind: "deadline", deadline: timeMs, reminderOffsets: [] };
        if (code) title = `验证码 ${code}`;
        break;
      }
      case "express": {
        const code = extractPickupCode(text);
        const fields: GenericField[] = [];
        if (code) fields.push({ key: "取件码", value: code, valueType: "string" });
        fields.push({ key: "内容", value: msg.body, valueType: "string" });
        payload = { fields };
        if (code) priority = "P1"; // 到达待取
        break;
      }
      case "bill": {
        const amount = extractAmount(text);
        const fields: GenericField[] = [];
        if (amount !== null) fields.push({ key: "金额", value: amount, valueType: "number" });
        if (timeMs) fields.push({ key: "截止", value: String(timeMs), valueType: "datetime" });
        fields.push({ key: "内容", value: msg.body, valueType: "string" });
        payload = { fields };
        if (timeMs) time = { kind: "deadline", deadline: timeMs, reminderOffsets: [1440, 120] };
        break;
      }
      case "coupon": {
        payload = { fields: [{ key: "内容", value: msg.body, valueType: "string" }] };
        if (timeMs) time = { kind: "deadline", deadline: timeMs, reminderOffsets: [] };
        break;
      }
      case "schedule": {
        payload = { event: msg.title || msg.body.slice(0, 30), notes: msg.body };
        if (timeMs) time = { kind: "point", startAt: timeMs, reminderOffsets: [60, 10] };
        break;
      }
      case "todo": {
        payload = { task: msg.body.slice(0, 50), status: "open", context: msg.title };
        if (timeMs) time = { kind: "deadline", deadline: timeMs, reminderOffsets: [120] };
        break;
      }
      case "note": {
        payload = { content: msg.body, tags: [] };
        break;
      }
      default: {
        const fields: GenericField[] = [
          { key: "标题", value: msg.title, valueType: "string" },
          { key: "内容", value: msg.body, valueType: "string" },
        ];
        if (timeMs) fields.push({ key: "时间", value: String(timeMs), valueType: "datetime" });
        payload = { fields };
        if (timeMs) time = { kind: "point", startAt: timeMs, reminderOffsets: [] };
        break;
      }
    }

    return {
      id: randomUUID(),
      rawMessageIds: [msg.id],
      category,
      schemaVersion: SCHEMA_VERSION,
      title,
      summary: msg.body.slice(0, 80),
      priority,
      confidence: category === "generic" ? 0.4 : 0.85,
      time,
      payload,
      processedBy: { provider: this.name, pipelineVersion: PIPELINE_VERSION },
    };
  }
}

// ---- 分类规则（顺序即优先级） ----

const RULES: Array<{ category: string; pattern: RegExp }> = [
  { category: "verification", pattern: /验证码|动态口令|校验码/ },
  { category: "express", pattern: /取件码|快递|包裹|驿站|揽收|派送|签收/ },
  { category: "bill", pattern: /账单|还款|缴费|欠款|水电费|话费/ },
  { category: "coupon", pattern: /优惠券|促销|满\s*\d+\s*减|折扣|秒杀|大促|抢购/ },
  { category: "schedule", pattern: /会议|开会|约会|航班|列车|火车|高铁|演出|预约|评审|面试|周会|例会/ },
  { category: "todo", pattern: /请.*(完成|提交|回复|处理)|记得|待办|别忘了/ },
];

export function classify(text: string): string {
  for (const rule of RULES) {
    if (rule.pattern.test(text)) return rule.category;
  }
  return "generic";
}

// ---- 字段抽取 ----

function extractVerificationCode(text: string): string | null {
  const m =
    /(?:验证码|动态口令|校验码)[^0-9]{0,8}([0-9]{4,8})/.exec(text) ??
    /(?<![0-9])([0-9]{6})(?![0-9])/.exec(text);
  return m ? m[1] : null;
}

function extractPickupCode(text: string): string | null {
  const m = /取件码[^A-Za-z0-9-]{0,8}([A-Za-z0-9][A-Za-z0-9-]{0,14})/.exec(text);
  return m ? m[1] : null;
}

function extractAmount(text: string): number | null {
  const m = /[¥￥]\s*([0-9]+(?:\.[0-9]{1,2})?)/.exec(text) ?? /([0-9]+(?:\.[0-9]{1,2})?)\s*元/.exec(text);
  return m ? Number(m[1]) : null;
}

// ---- 中文相对时间解析，基准为 postedAt ----

const DAY_OFFSETS: Record<string, number> = { 今天: 0, 明天: 1, 后天: 2, 大后天: 3 };

export function extractTimeMs(text: string, baseAt: number): number | null {
  let m = /(\d{1,3})\s*小时后/.exec(text);
  if (m) return baseAt + Number(m[1]) * 3_600_000;

  m = /(\d{1,3})\s*分钟[内后]/.exec(text);
  if (m) return baseAt + Number(m[1]) * 60_000;

  m = /(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]/.exec(text);
  if (m) {
    const base = new Date(baseAt);
    const month = Number(m[1]) - 1;
    const day = Number(m[2]);
    let d = new Date(base.getFullYear(), month, day, 23, 59, 0, 0);
    if (d.getTime() < baseAt) d = new Date(base.getFullYear() + 1, month, day, 23, 59, 0, 0);
    return d.getTime();
  }

  const dayM = /(今天|明天|后天|大后天)/.exec(text);
  const timeM = /(凌晨|上午|中午|下午|晚上)?\s*(\d{1,2})\s*(?:[:：点])\s*(\d{1,2})?\s*分?/.exec(text);
  if (!dayM && !timeM) return null;

  const base = new Date(baseAt);
  const dayOffset = dayM ? DAY_OFFSETS[dayM[1]] : 0;
  const d = new Date(base.getFullYear(), base.getMonth(), base.getDate() + dayOffset, 0, 0, 0, 0);
  if (timeM) {
    let hour = Number(timeM[2]);
    const minute = timeM[3] !== undefined ? Number(timeM[3]) : 0;
    const period = timeM[1];
    if ((period === "下午" || period === "晚上") && hour < 12) hour += 12;
    if (period === "中午" && hour < 12) hour += 12;
    d.setHours(hour, minute, 0, 0);
    // 无日期词且时间已过，顺延到明天
    if (!dayM && d.getTime() <= baseAt) d.setDate(d.getDate() + 1);
  } else {
    // 只有日期词没有具体时间：按当天结束处理
    d.setHours(23, 59, 0, 0);
  }
  return d.getTime();
}

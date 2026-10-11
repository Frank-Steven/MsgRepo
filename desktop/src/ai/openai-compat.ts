import { randomUUID } from "node:crypto";
import { buildDateHints, normalizeTime, type AIProvider } from "./provider.js";
import {
  PIPELINE_VERSION,
  SCHEMA_VERSION,
  type CategoryRegistry,
  type Priority,
  type RawMessage,
  type StructuredItem,
} from "../types.js";

/**
 * OpenAI 兼容 provider：POST {baseUrl}/chat/completions，
 * response_format=json_object，一次调用产出完整结果。
 * payloadSchema 与基准时间写进 prompt，模型直接输出绝对毫秒时间戳。
 */
export class OpenAICompatProvider implements AIProvider {
  readonly name = "openai-compatible";
  readonly model: string;

  constructor(private readonly opts: { baseUrl: string; model: string; apiKey?: string }) {
    this.model = opts.model;
  }

  async process(messages: RawMessage[], registry: CategoryRegistry): Promise<StructuredItem[]> {
    const results: StructuredItem[] = [];
    for (const msg of messages) {
      results.push(await this.processOne(msg, registry));
    }
    return results;
  }

  private async processOne(msg: RawMessage, registry: CategoryRegistry): Promise<StructuredItem> {
    const catList = registry.categories
      .map(
        (c) =>
          `- ${c.key}（${c.displayName}）: ${c.description}` +
          `${c.priorityHints ? ` 优先级提示：${c.priorityHints}` : ""}` +
          `${c.timeHints ? ` 时间提示：${c.timeHints}` : ""}`,
      )
      .join("\n");
    const payloadSchemas = Object.fromEntries(
      registry.categories.map((c) => [c.key, c.payloadSchema]),
    );

    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (this.opts.apiKey) headers.Authorization = `Bearer ${this.opts.apiKey}`;

    const makeBody = (withResponseFormat: boolean) =>
      JSON.stringify({
        model: this.opts.model,
        temperature: 0,
        ...(withResponseFormat ? { response_format: { type: "json_object" } } : {}),
        messages: [
          {
            role: "system",
            content:
              `你是消息结构化助手。为消息返回 JSON 对象：\n` +
              `{"category","title","summary","priority","confidence","time","payload"}\n` +
              `category 必须是以下之一：\n${catList}\n` +
              `priority 取 P0/P1/P2/P3。confidence 取 0~1。\n` +
              `time 形如 {"kind":"none|point|range|deadline|recurring","startAt"?,"endAt"?,"deadline"?,"rrule"?,"reminderOffsets"?}，` +
              `其中 startAt/endAt/deadline 用本地时间字符串 "YYYY-MM-DDTHH:mm" 输出（不要自行换算毫秒），` +
              `相对日期（如"本周五""下周一"）查用户消息里的日期对照表确定。` +
              `解析出的时间必须晚于基准时间：若字面日期标注了"已过去"，顺延到下一个未来的同名日期（如"本周五"已过则取"下周五"）。\n` +
              `payload 必须符合所选分类的 payloadSchema：${JSON.stringify(payloadSchemas)}\n只输出 JSON。`,
          },
          {
            role: "user",
            content: JSON.stringify({
              基准时间: new Date(msg.postedAt).toLocaleString("zh-CN", {
                weekday: "long",
                year: "numeric",
                month: "numeric",
                day: "numeric",
                hour: "numeric",
                minute: "numeric",
                hour12: false,
              }),
              日期对照表: buildDateHints(msg.postedAt),
              标题: msg.title,
              正文: msg.body,
            }),
          },
        ],
      });

    // 部分本地服务（如 llama.cpp 旧版）不支持 response_format，400 时降级为纯 prompt 约束
    let res = await fetch(`${this.opts.baseUrl}/chat/completions`, {
      method: "POST",
      headers,
      body: makeBody(true),
    });
    if (!res.ok) {
      const errText = await res.text();
      const formatUnsupported =
        res.status === 400 && /response_format|structured output/i.test(errText);
      if (!formatUnsupported) throw new Error(`OpenAI 兼容接口返回 ${res.status}: ${errText}`);
      res = await fetch(`${this.opts.baseUrl}/chat/completions`, {
        method: "POST",
        headers,
        body: makeBody(false),
      });
      if (!res.ok) throw new Error(`OpenAI 兼容接口返回 ${res.status}: ${await res.text()}`);
    }
    const data = (await res.json()) as { choices?: Array<{ message?: { content?: string } }> };
    const content = data.choices?.[0]?.message?.content ?? "{}";
    // 模型可能把 JSON 包在 markdown 代码围栏或前后缀文字里，取首个 { 到末个 } 之间
    const start = content.indexOf("{");
    const end = content.lastIndexOf("}");
    if (start === -1 || end <= start) throw new Error(`模型未返回 JSON: ${content.slice(0, 200)}`);
    const out = JSON.parse(content.slice(start, end + 1)) as {
      category?: string;
      title?: string;
      summary?: string;
      priority?: Priority;
      confidence?: number;
      time?: unknown;
      payload?: Record<string, unknown>;
    };

    const category =
      out.category && registry.categories.some((c) => c.key === out.category)
        ? out.category
        : "generic";

    return {
      id: randomUUID(),
      rawMessageIds: [msg.id],
      category,
      schemaVersion: SCHEMA_VERSION,
      title: String(out.title ?? msg.title),
      summary: String(out.summary ?? ""),
      priority: out.priority as Priority,
      confidence: Number(out.confidence ?? 0.5),
      time: normalizeTime(out.time),
      payload: (out.payload ?? {}) as Record<string, unknown>,
      processedBy: { provider: this.name, model: this.opts.model, pipelineVersion: PIPELINE_VERSION },
    };
  }
}

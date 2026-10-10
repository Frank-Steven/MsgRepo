import { randomUUID } from "node:crypto";
import { normalizeTime, type AIProvider } from "./provider.js";
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

    const res = await fetch(`${this.opts.baseUrl}/chat/completions`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        model: this.opts.model,
        temperature: 0,
        response_format: { type: "json_object" },
        messages: [
          {
            role: "system",
            content:
              `你是消息结构化助手。为消息返回 JSON 对象：\n` +
              `{"category","title","summary","priority","confidence","time","payload"}\n` +
              `category 必须是以下之一：\n${catList}\n` +
              `priority 取 P0/P1/P2/P3。confidence 取 0~1。\n` +
              `time 形如 {"kind":"none|point|range|deadline|recurring","startAt"?,"endAt"?,"deadline"?,"rrule"?,"reminderOffsets"?}，` +
              `所有相对时间以基准时间为准，输出 Unix 毫秒绝对时间戳。\n` +
              `payload 必须符合所选分类的 payloadSchema：${JSON.stringify(payloadSchemas)}\n只输出 JSON。`,
          },
          {
            role: "user",
            content: JSON.stringify({
              基准时间: new Date(msg.postedAt).toISOString(),
              基准时间戳: msg.postedAt,
              标题: msg.title,
              正文: msg.body,
            }),
          },
        ],
      }),
    });
    if (!res.ok) throw new Error(`OpenAI 兼容接口返回 ${res.status}: ${await res.text()}`);
    const data = (await res.json()) as { choices?: Array<{ message?: { content?: string } }> };
    const content = data.choices?.[0]?.message?.content ?? "{}";
    const out = JSON.parse(content) as {
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

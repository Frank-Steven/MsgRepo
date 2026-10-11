import { randomUUID } from "node:crypto";
import { buildDateHints, normalizeTime, type AIProvider } from "./provider.js";
import {
  PIPELINE_VERSION,
  SCHEMA_VERSION,
  type CategoryDef,
  type CategoryRegistry,
  type Priority,
  type RawMessage,
  type StructuredItem,
} from "../types.js";

interface ChatMessage {
  role: "system" | "user";
  content: string;
}

/**
 * Ollama provider：两步调用。
 * 1) 分类 + 标题/摘要/优先级/时间（format 传统一的 meta schema）；
 * 2) 按分类 payloadSchema 作为 format 约束模型输出 payload JSON。
 * 基准时间（postedAt）写进 prompt，模型直接输出绝对毫秒时间戳。
 */
export class OllamaProvider implements AIProvider {
  readonly name = "ollama";
  readonly model: string;

  constructor(private readonly opts: { baseUrl: string; model: string }) {
    this.model = opts.model;
  }

  async process(messages: RawMessage[], registry: CategoryRegistry): Promise<StructuredItem[]> {
    const results: StructuredItem[] = [];
    for (const msg of messages) {
      results.push(await this.processOne(msg, registry));
    }
    return results;
  }

  private async chat(messages: ChatMessage[], format?: Record<string, unknown>): Promise<string> {
    const res = await fetch(`${this.opts.baseUrl}/api/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: this.opts.model,
        messages,
        stream: false,
        ...(format ? { format } : {}),
      }),
    });
    if (!res.ok) throw new Error(`Ollama /api/chat 返回 ${res.status}: ${await res.text()}`);
    const data = (await res.json()) as { message?: { content?: string } };
    return data.message?.content ?? "";
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

    const metaSchema: Record<string, unknown> = {
      type: "object",
      properties: {
        category: { type: "string", enum: registry.categories.map((c) => c.key) },
        title: { type: "string" },
        summary: { type: "string" },
        priority: { type: "string", enum: ["P0", "P1", "P2", "P3"] },
        confidence: { type: "number" },
        time: {
          type: "object",
          properties: {
            kind: { type: "string", enum: ["none", "point", "range", "deadline", "recurring"] },
            startAt: { type: "string", description: "本地时间 YYYY-MM-DDTHH:mm" },
            endAt: { type: "string", description: "本地时间 YYYY-MM-DDTHH:mm" },
            deadline: { type: "string", description: "本地时间 YYYY-MM-DDTHH:mm" },
            rrule: { type: "string" },
            reminderOffsets: { type: "array", items: { type: "integer" } },
          },
          required: ["kind"],
        },
      },
      required: ["category", "title", "summary", "priority", "confidence", "time"],
    };

    const metaRaw = await this.chat(
      [
        {
          role: "system",
          content:
            `你是消息结构化助手。从下列分类中为消息选择最合适的一个，提炼标题、一句话摘要、优先级、置信度和时间。\n` +
            `分类列表：\n${catList}\n` +
            `时间字段 startAt/endAt/deadline 用本地时间字符串 "YYYY-MM-DDTHH:mm" 输出（不要自行换算毫秒），` +
            `相对日期查用户消息里的日期对照表确定；解析出的时间必须晚于基准时间，` +
            `若字面日期标注了"已过去"，顺延到下一个未来的同名日期（如"本周五"已过则取"下周五"）。只输出 JSON。`,
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
      metaSchema,
    );
    const meta = JSON.parse(metaRaw) as {
      category: string;
      title: string;
      summary: string;
      priority: Priority;
      confidence: number;
      time: unknown;
    };

    const catDef =
      registry.categories.find((c) => c.key === meta.category) ??
      (registry.categories.find((c) => c.key === "generic") as CategoryDef);

    // format 传该分类 payloadSchema 约束 JSON 输出
    const payloadSchema: Record<string, unknown> = {
      ...catDef.payloadSchema,
      ...(registry.definitions ? { definitions: registry.definitions } : {}),
    };
    const payloadRaw = await this.chat(
      [
        {
          role: "system",
          content: `按给定 JSON Schema 抽取「${catDef.displayName}」分类的 payload。只输出符合 schema 的 JSON。`,
        },
        {
          role: "user",
          content: JSON.stringify({ 标题: msg.title, 正文: msg.body, 基准时间戳: msg.postedAt }),
        },
      ],
      payloadSchema,
    );

    return {
      id: randomUUID(),
      rawMessageIds: [msg.id],
      category: catDef.key,
      schemaVersion: SCHEMA_VERSION,
      title: String(meta.title ?? msg.title),
      summary: String(meta.summary ?? ""),
      priority: meta.priority,
      confidence: Number(meta.confidence ?? 0.5),
      time: normalizeTime(meta.time),
      payload: JSON.parse(payloadRaw) as Record<string, unknown>,
      processedBy: { provider: this.name, model: this.opts.model, pipelineVersion: PIPELINE_VERSION },
    };
  }
}

import { randomUUID } from "node:crypto";
import {
  appendCustomPrompt,
  buildDateHints,
  normalizeTime,
  type AIProvider,
  type ProcessOptions,
} from "./provider.js";
import {
  PIPELINE_VERSION,
  SCHEMA_VERSION,
  type CategoryRegistry,
  type Priority,
  type RawMessage,
  type StructuredItem,
} from "../types.js";

interface ModelOutput {
  category?: string;
  title?: string;
  summary?: string;
  priority?: Priority;
  confidence?: number;
  time?: unknown;
  payload?: Record<string, unknown>;
}

/**
 * OpenAI 兼容 provider：POST {baseUrl}/chat/completions，
 * response_format=json_object（不支持时 400 降级为纯 prompt 约束），一次调用产出完整结果。
 * 首次分类落到 generic 时自动发起第二次更强势的分类请求，尽可能归入具体分类。
 */
export class OpenAICompatProvider implements AIProvider {
  readonly name = "openai-compatible";
  readonly model: string;

  constructor(private readonly opts: { baseUrl: string; model: string; apiKey?: string }) {
    this.model = opts.model;
  }

  async process(
    messages: RawMessage[],
    registry: CategoryRegistry,
    options?: ProcessOptions,
  ): Promise<StructuredItem[]> {
    const results: StructuredItem[] = [];
    for (const msg of messages) {
      results.push(await this.processOne(msg, registry, options));
    }
    return results;
  }

  private resolveCategory(raw: string | undefined, registry: CategoryRegistry): string {
    return raw && registry.categories.some((c) => c.key === raw) ? raw : "generic";
  }

  /** 发送一次 chat/completions 并解析出 JSON 对象；两次分类请求共用这套逻辑。 */
  private async requestStructured(systemContent: string, userContent: string): Promise<ModelOutput> {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (this.opts.apiKey) headers.Authorization = `Bearer ${this.opts.apiKey}`;

    const makeBody = (withResponseFormat: boolean) =>
      JSON.stringify({
        model: this.opts.model,
        temperature: 0,
        ...(withResponseFormat ? { response_format: { type: "json_object" } } : {}),
        messages: [
          { role: "system", content: systemContent },
          { role: "user", content: userContent },
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
    return JSON.parse(content.slice(start, end + 1)) as ModelOutput;
  }

  private async processOne(
    msg: RawMessage,
    registry: CategoryRegistry,
    options?: ProcessOptions,
  ): Promise<StructuredItem> {
    const formatCat = (c: CategoryRegistry["categories"][number]) =>
      `- ${c.key}（${c.displayName}）: ${c.description}` +
      `${c.priorityHints ? ` 优先级提示：${c.priorityHints}` : ""}` +
      `${c.timeHints ? ` 时间提示：${c.timeHints}` : ""}`;
    const catList = registry.categories.map(formatCat).join("\n");
    // payloadSchema 内含 "$ref": "#/definitions/genericField"，必须把 definitions
    // 一并附进 prompt，否则模型无法解析引用、只能猜测字段名（实测会输出 name 而非 key）
    const payloadSchemas = Object.fromEntries(
      registry.categories.map((c) => [
        c.key,
        registry.definitions
          ? { ...c.payloadSchema, definitions: registry.definitions }
          : c.payloadSchema,
      ]),
    );
    const formatSpec =
      `priority 取 P0/P1/P2/P3。confidence 取 0~1。\n` +
      `time 形如 {"kind":"none|point|range|deadline|recurring","startAt"?,"endAt"?,"deadline"?,"rrule"?,"reminderOffsets"?}，` +
      `其中 startAt/endAt/deadline 用本地时间字符串 "YYYY-MM-DDTHH:mm" 输出（不要自行换算毫秒），` +
      `相对日期（如"本周五""下周一"）查用户消息里的日期对照表确定。` +
      `解析出的时间必须晚于基准时间：若字面日期标注了"已过去"，顺延到下一个未来的同名日期（如"本周五"已过则取"下周五"）。\n` +
      `payload 必须符合所选分类的 payloadSchema：${JSON.stringify(payloadSchemas)}\n只输出 JSON。`;

    const userContent = JSON.stringify({
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
    });

    const systemPrompt = appendCustomPrompt(
      `你是消息结构化助手。为消息返回 JSON 对象：\n` +
        `{"category","title","summary","priority","confidence","time","payload"}\n` +
        `category 必须是以下之一：\n${catList}\n` +
        formatSpec,
      options?.customPrompt,
    );

    let out = await this.requestStructured(systemPrompt, userContent);
    let category = this.resolveCategory(out.category, registry);
    let retried = false;

    // generic 二次分类：generic 是兜底，用更强势的 prompt 逼模型在具体分类中选最贴近的
    if (category === "generic") {
      retried = true;
      const specificList = registry.categories
        .filter((c) => c.key !== "generic")
        .map(formatCat)
        .join("\n");
      const retrySystem = appendCustomPrompt(
        `你是消息结构化助手。为消息返回 JSON 对象：\n` +
          `{"category","title","summary","priority","confidence","time","payload"}\n` +
          `重要：generic（未分类）是最后手段，禁止轻易使用。必须从以下具体分类中选出与消息最贴近的一个（即使只有部分相关，也要选最接近的）：\n${specificList}\n` +
          `只有当消息确实与以上所有分类都毫无关系时，才允许 category="generic"。\n` +
          formatSpec,
        options?.customPrompt,
      );
      const retry = await this.requestStructured(retrySystem, userContent);
      const retryCategory = this.resolveCategory(retry.category, registry);
      if (retryCategory !== "generic") {
        // 二次成功：category/title/summary/priority/confidence/time/payload 全部采用二次结果
        out = retry;
        category = retryCategory;
        retried = false;
      }
    }

    let confidence = Number(out.confidence ?? 0.5);
    if (retried) confidence = Math.min(confidence, 0.4); // 二次仍 generic：压低置信度让手机端标记"待确认"

    return {
      id: randomUUID(),
      rawMessageIds: [msg.id],
      category,
      schemaVersion: SCHEMA_VERSION,
      title: String(out.title ?? msg.title),
      summary: String(out.summary ?? ""),
      priority: out.priority as Priority,
      confidence,
      time: normalizeTime(out.time),
      payload: (out.payload ?? {}) as Record<string, unknown>,
      processedBy: { provider: this.name, model: this.opts.model, pipelineVersion: PIPELINE_VERSION },
    };
  }
}

import { randomUUID } from "node:crypto";
import {
  appendCustomPrompt,
  buildDateHints,

  type AIProvider,
  type EvaluateOptions,

} from "./provider.js";
import {
  buildEvalBatchSystemPrompt,
  buildEvalBatchUserContent,
  buildEvalSystemPrompt,
  buildEvalUserContent,
  parseEvalBatchOutput,
  parseEvalOutput,
} from "./evaluate.js";
import {


  type CategoryRegistry,
  type EvalResult,

  type ProcessInputMessage,


} from "../types.js";


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


  private resolveCategory(raw: string | undefined, registry: CategoryRegistry): string {
    return raw && registry.categories.some((c) => c.key === raw) ? raw : "generic";
  }


  /**
   * v2 流式评估：stream=true 调 /chat/completions，SSE 逐行解析 choices[0].delta.content
   * 回调 onToken，同时累积全文，结束后解析出精简评估结果（设计 §8.2/§8.3）。
   */
  async evaluateStreaming(
    message: ProcessInputMessage,
    registry: CategoryRegistry,
    options: EvaluateOptions,
  ): Promise<EvalResult> {
    const full = await this.streamCompletion(
      buildEvalSystemPrompt(registry, options.customPrompt),
      buildEvalUserContent(message, options.now),
      options.onToken,
    );
    return parseEvalOutput(full);
  }

  /**
   * v2.6.1 批量流式评估（省 Token）：多条消息合并一次请求，schema 返回结果数组
   * 按 messageId 一一对应；系统提示词每批只传一次。
   */
  async evaluateBatchStreaming(
    messages: ProcessInputMessage[],
    registry: CategoryRegistry,
    options: EvaluateOptions,
  ): Promise<Map<string, EvalResult>> {
    const full = await this.streamCompletion(
      buildEvalBatchSystemPrompt(registry, options.customPrompt),
      buildEvalBatchUserContent(messages, options.now),
      options.onToken,
    );
    return parseEvalBatchOutput(messages, full);
  }

  /** 发送一次 stream=true 的 chat/completions，SSE 逐段回调 onToken，返回累积全文。 */
  private async streamCompletion(
    systemContent: string,
    userContent: string,
    onToken?: (delta: string) => void,
  ): Promise<string> {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (this.opts.apiKey) headers.Authorization = `Bearer ${this.opts.apiKey}`;

    const res = await fetch(`${this.opts.baseUrl}/chat/completions`, {
      method: "POST",
      headers,
      signal: AbortSignal.timeout(180_000),
      body: JSON.stringify({
        model: this.opts.model,
        temperature: 0,
        stream: true,
        messages: [
          { role: "system", content: systemContent },
          { role: "user", content: userContent },
        ],
      }),
    });
    if (!res.ok || !res.body) {
      throw new Error(`OpenAI 兼容接口返回 ${res.status}: ${await res.text()}`);
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    let full = "";
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        let nl = buf.indexOf("\n");
        while (nl >= 0) {
          const line = buf.slice(0, nl).trim();
          buf = buf.slice(nl + 1);
          nl = buf.indexOf("\n");
          if (!line.startsWith("data:")) continue;
          const data = line.slice(5).trim();
          if (data === "[DONE]") continue;
          try {
            const json = JSON.parse(data) as {
              choices?: Array<{ delta?: { content?: string } }>;
            };
            const delta = json.choices?.[0]?.delta?.content;
            if (typeof delta === "string" && delta.length > 0) {
              full += delta;
              onToken?.(delta);
            }
          } catch {
            // 忽略不完整的 JSON 行/保活注释
          }
        }
      }
    } finally {
      reader.releaseLock();
    }
    return full;
  }

}

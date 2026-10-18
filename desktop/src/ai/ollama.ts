import { randomUUID } from "node:crypto";
import {
  appendCustomPrompt,
  buildDateHints,

  type AIProvider,

} from "./provider.js";
import {


  type CategoryDef,
  type CategoryRegistry,



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

}

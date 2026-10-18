import type { AIProvider } from "./ai/provider.js";
import { junkRuleHit } from "./ai/junk-rules.js";
import type { CategoryRegistry, ProcessInputMessage, ProcessEvent } from "./types.js";

// P3-12：v1 管线（runPipeline / StructuredItem / 去重归并 / payload 校验 / Store 落盘）
// 已整体移除——v2 的 AI 链路只有 processStreaming（逐条或批量 eval），
// 由 /v1/process 与手机端 AiClient 消费。

export interface ProcessStreamingOptions {
  customPrompt?: string;
  /** 手机端"现在"（毫秒），日期对照表基准 */
  now: number;
  /** 每个事件（token/result/error）立即回调，由 server 逐行写入 NDJSON 流 */
  onEvent?: (event: ProcessEvent) => void;
}

/** 单次批量的消息数上限（v2.6.1 省 Token：批量合并请求，分批发送；
 *  与 mobile AiClient.batchSize 一致）。 */
export const EVAL_BATCH_SIZE = 10;

/**
 * v2.6.1：先跑本地垃圾规则预过滤（命中直接判 junk，不消耗 Token）；其余消息
 * provider 支持批量时按 EVAL_BATCH_SIZE 分批合并请求（token 事件归批首消息，
 * 结果按 messageId 拆分），不支持时回退逐条评估。单条/单批失败不影响后续。
 * 不落盘（电脑端无业务数据，设计 §11）。
 */
/**
 * 整批失败后是否值得降级为逐条重试（P1-2 收紧）。
 *
 * 只有「模型输出本身不合格」才拆开重发；配置错误（400/401/404）、网络与超时会让
 * 整批以同样方式失败，逐条重发只会把同一份全量提示词付 N 次（实测 15 条消息被放大
 * 成 15 次请求）。
 */
export function shouldRetryPerMessage(errorText: string): boolean {
  return (
    errorText.includes("模型未返回 JSON 数组") ||
    errorText.includes("模型输出不是 JSON 数组") ||
    errorText.includes("模型输出 JSON 解析失败") ||
    errorText.includes("模型未返回 JSON:")
  );
}

export async function processStreaming(
  messages: ProcessInputMessage[],
  registry: CategoryRegistry,
  provider: AIProvider,
  options: ProcessStreamingOptions,
): Promise<{ total: number; failed: number }> {
  const emit = options.onEvent ?? (() => undefined);
  let failed = 0;

  // 本地规则预过滤（两端同一套规则：mobile/lib/services/junk_rules.dart）
  const toEval: ProcessInputMessage[] = [];
  for (const msg of messages) {
    const hit = junkRuleHit(msg);
    if (hit) {
      emit({ type: "result", messageId: msg.id, priority: "junk", reason: hit, taskDraft: null });
    } else {
      toEval.push(msg);
    }
  }
  if (toEval.length === 0) return { total: messages.length, failed };

  if (typeof provider.evaluateBatchStreaming === "function") {
    for (let i = 0; i < toEval.length; i += EVAL_BATCH_SIZE) {
      const batch = toEval.slice(i, i + EVAL_BATCH_SIZE);
      const streamId = batch[0].id; // 流式原文归批首消息的卡片
      try {
        const results = await provider.evaluateBatchStreaming(batch, registry, {
          customPrompt: options.customPrompt,
          now: options.now,
          onToken: (delta) => emit({ type: "token", messageId: streamId, delta }),
        });
        for (const msg of batch) {
          const result = results.get(msg.id);
          if (result) {
            emit({ type: "result", messageId: msg.id, ...result });
          } else {
            failed++;
            emit({ type: "error", messageId: msg.id, error: "模型未返回该条结果" });
          }
        }
      } catch (err) {
        // P1-2：整批失败时降级为逐条重试（模型偶尔返回非数组/被截断，
        // 整批报废的代价太大）。单条仍失败才计入 failed。
        if (
          batch.length > 1 &&
          typeof provider.evaluateStreaming === "function" &&
          shouldRetryPerMessage(String(err))
        ) {
          for (const msg of batch) {
            try {
              const single = await provider.evaluateStreaming(msg, registry, {
                customPrompt: options.customPrompt,
                now: options.now,
                onToken: (delta) => emit({ type: "token", messageId: msg.id, delta }),
              });
              emit({ type: "result", messageId: msg.id, ...single });
            } catch (err2) {
              failed++;
              emit({ type: "error", messageId: msg.id, error: String(err2) });
            }
          }
          continue;
        }
        failed += batch.length;
        for (const msg of batch) {
          emit({ type: "error", messageId: msg.id, error: String(err) });
        }
      }
    }
    return { total: messages.length, failed };
  }

  // 回退：provider 不支持批量时逐条评估
  for (const msg of toEval) {
    if (typeof provider.evaluateStreaming !== "function") {
      failed++;
      emit({
        type: "error",
        messageId: msg.id,
        error: `AI provider (${provider.name}) 不支持流式评估`,
      });
      continue;
    }
    try {
      const result = await provider.evaluateStreaming(msg, registry, {
        customPrompt: options.customPrompt,
        now: options.now,
        onToken: (delta) => emit({ type: "token", messageId: msg.id, delta }),
      });
      emit({ type: "result", messageId: msg.id, ...result });
    } catch (err) {
      failed++;
      emit({ type: "error", messageId: msg.id, error: String(err) });
    }
  }
  return { total: messages.length, failed };
}

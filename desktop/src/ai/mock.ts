import type { AIProvider, EvaluateOptions } from "./provider.js";
import type { CategoryRegistry, EvalPriority, EvalResult, ProcessInputMessage } from "../types.js";

/**
 * 规则引擎 provider（P3-12 精简版）：不依赖任何模型也能端到端跑通 /v1/process。
 *
 * v1 的 process()（StructuredItem + 关键词分类 + 正则抽取 + 归并）随 v1 管线一并删除，
 * 这里只保留 v2 的逐条/批量评估，用少量关键词给出确定性结果，供无模型环境联调。
 */
export class MockProvider implements AIProvider {
  readonly name = "mock";

  readonly model = "mock-rules";

  private judge(message: ProcessInputMessage): EvalResult {
    const text = `${message.title} ${message.body}`;
    const junk = /(退订|秒杀|限时|领取|红包|刷单|兼职|0元购)/.test(text);
    const actionable = /(开会|评审|截止|提醒|提交|报名|缴费|还款)/.test(text);
    const priority: EvalPriority = junk ? "junk" : actionable ? "red" : "green";
    return {
      priority,
      reason: junk
        ? "命中营销关键词（mock 规则）"
        : actionable
          ? "含可执行事项（mock 规则）"
          : "无明确事项（mock 规则）",
      taskDraft: null,
    };
  }

  async evaluateStreaming(
    message: ProcessInputMessage,
    _registry: CategoryRegistry,
    _options: EvaluateOptions,
  ): Promise<EvalResult> {
    return this.judge(message);
  }

  async evaluateBatchStreaming(
    messages: ProcessInputMessage[],
    _registry: CategoryRegistry,
    _options: EvaluateOptions,
  ): Promise<Map<string, EvalResult>> {
    return new Map(messages.map((m) => [m.id, this.judge(m)]));
  }
}

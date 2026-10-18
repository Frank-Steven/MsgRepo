import type {
  CategoryRegistry,
  EvalResult,
  ProcessInputMessage,
} from "../types.js";


/** v2 流式评估选项（设计 §8.3）。 */
export interface EvaluateOptions {
  customPrompt?: string;
  /** 手机端"现在"（毫秒），日期对照表与"已过去顺延"的基准 */
  now: number;
  /** 每生成一段 delta 回调一次，供 /v1/process 透传 token 事件 */
  onToken?: (delta: string) => void;
}

/** AI 适配器接口（v2，P3-12 精简）：只保留逐条/批量评估，v1 的 process 已删除。 */
export interface AIProvider {
  readonly name: string;
  readonly model?: string;
  /** v2 流式评估（可选实现）：对单条消息产出 priority + reason + 可选任务草稿。 */
  evaluateStreaming?(
    message: ProcessInputMessage,
    registry: CategoryRegistry,
    options: EvaluateOptions,
  ): Promise<EvalResult>;
  /** v2.6.1 批量流式评估（可选实现，省 Token）：多条消息合并一次请求，
   *  结果按 messageId 一一对应返回；未实现的 provider 由管线回退为逐条评估。 */
  evaluateBatchStreaming?(
    messages: ProcessInputMessage[],
    registry: CategoryRegistry,
    options: EvaluateOptions,
  ): Promise<Map<string, EvalResult>>;
}

/** 把用户自定义提示词追加到系统提示词末尾。 */
export function appendCustomPrompt(system: string, customPrompt?: string): string {
  if (!customPrompt || !customPrompt.trim()) return system;
  return (
    system +
    `\n用户附加要求（优先级高于默认规则，但不违反输出 JSON 格式）：\n${customPrompt.trim()}`
  );
}


/** 生成日期对照表，放进 prompt 让模型查表而不是做日期算术（周一为一周第一天）。 */
export function buildDateHints(postedAt: number): string {
  const base = new Date(postedAt);
  const weekChars = "日一二三四五六";
  const fmt = (d: Date) =>
    `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日（周${weekChars[d.getDay()]}）`;
  const day = (offset: number) => {
    const d = new Date(base);
    d.setDate(d.getDate() + offset);
    return d;
  };
  const lines = [`今天=${fmt(day(0))}`, `明天=${fmt(day(1))}`, `后天=${fmt(day(2))}`];
  const dow = (base.getDay() + 6) % 7;
  const names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];
  const past = (offset: number) => (offset < 0 ? "（已过去）" : "");
  for (let i = 0; i < 7; i++) lines.push(`本${names[i]}=${fmt(day(i - dow))}${past(i - dow)}`);
  for (let i = 0; i < 7; i++) lines.push(`下${names[i]}=${fmt(day(i - dow + 7))}`);
  return lines.join("\n");
}

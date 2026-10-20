import { appendCustomPrompt, buildDateHints } from "./provider.js";
import type {
  CategoryRegistry,
  EvalPriority,
  EvalResult,
  ProcessInputMessage,
  TaskDraft,
} from "../types.js";

const EVAL_PRIORITIES = new Set(["red", "yellow", "green", "junk"]);
const TASK_PRIORITIES = new Set(["important", "normal", "minor"]);

/** v2 评估的系统提示词：精简输出 schema（设计 §8.2），分类注册表作为重要性判断参考。 */
export function buildEvalSystemPrompt(
  registry: CategoryRegistry,
  customPrompt?: string,
): string {
  const catList = registry.categories
    .map(
      (c) =>
        `- ${c.key}（${c.displayName}）: ${c.description}` +
        `${c.priorityHints ? ` 优先级提示：${c.priorityHints}` : ""}`,
    )
    .join("\n");
  return appendCustomPrompt(
    `你是消息评估助手。为消息输出一个 JSON 对象：\n` +
      `{"priority":"red|yellow|green|junk","reason":"一句话理由","taskDraft":null 或 ` +
      `{"title":"...","description":"...","kind":"point|range","startAt":"YYYY-MM-DDTHH:mm","endAt":"YYYY-MM-DDTHH:mm","priority":"important|normal|minor"}}\n` +
      `priority 语义：red=重要、yellow=值得关注、green=一般、junk=垃圾（营销、推广、无用系统提示等）。` +
      `判断重要与垃圾是首要职责。结合来源应用与会话语境判断（如银行/支付类通知多重要、` +
      `应用商店的推广多为垃圾）。\n` +
      `taskDraft 规则：\n` +
      `- 消息包含明确可执行事项时给出，否则为 null；「值得留存备查」不构成建任务的理由` +
      `（笔记类草稿已于 2026-10-20 取消，见 mobile 提示词注释）。\n` +
      `- title 不超过 20 个字符（中文按 2 字符计），超长的细节放入 description。\n` +
      `- kind=point 时点任务只需 startAt；kind=range 时段任务需要 startAt 和 endAt；` +
      `没有明确时间的可执行事项省略 startAt/endAt（不定时任务）。\n` +
      `- 消息包含一个主事项和多个子步骤时，只给主事项草稿，子步骤以换行列表写进 ` +
      `description，不要拆成多个草稿。\n` +
      `- 任务 priority：important=重要、normal=一般、minor=不重要。\n` +
      `时间用本地时间字符串 "YYYY-MM-DDTHH:mm" 输出（不要自行换算毫秒），相对日期（如"本周五""下周一"）` +
      `查用户消息里的日期对照表确定；解析出的时间必须晚于基准时间：若字面日期标注了"已过去"，顺延到下一个未来的同名日期。\n` +
      `分类参考（辅助判断重要性与垃圾）：\n${catList}\n` +
      `只输出 JSON。`,
    customPrompt,
  );
}

/** 用户消息：基准时间 + 日期对照表 + 消息字段（相对日期查表，不做日期算术）。 */
export function buildEvalUserContent(msg: ProcessInputMessage, now: number): string {
  return JSON.stringify({
    基准时间: new Date(now).toLocaleString("zh-CN", {
      weekday: "long",
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
      hour12: false,
    }),
    日期对照表: buildDateHints(now),
    消息时间: new Date(msg.postedAt).toLocaleString("zh-CN", { hour12: false }),
    来源应用: msg.appName,
    会话: msg.conversationTitle,
    发送者: msg.sender,
    标题: msg.title,
    正文: msg.body,
  });
}

/** N1：把 taskDrafts 数组与兼容的单个 taskDraft 归一成列表（每项已校验 title）。 */
function normalizeTaskDrafts(multi: unknown, single: unknown): TaskDraft[] {
  const out: TaskDraft[] = [];
  if (Array.isArray(multi)) {
    for (const item of multi) {
      const d = normalizeTaskDraft(item);
      if (d) out.push(d);
      if (out.length >= 3) break;
    }
  }
  if (out.length === 0) {
    const d = normalizeTaskDraft(single);
    if (d) out.push(d);
  }
  return out;
}

function normalizeTaskDraft(raw: unknown): TaskDraft | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  if (typeof o.title !== "string" || !o.title.trim()) return null;
  const draft: TaskDraft = {
    title: o.title.trim(),
    kind: o.kind === "range" ? "range" : "point",
    priority:
      typeof o.priority === "string" && TASK_PRIORITIES.has(o.priority)
        ? (o.priority as TaskDraft["priority"])
        : "normal",
  };
  if (typeof o.description === "string" && o.description.trim()) {
    draft.description = o.description.trim();
  }
  for (const key of ["startAt", "endAt"] as const) {
    const v = o[key];
    if (typeof v === "string") {
      const ms = new Date(v.trim().replace(" ", "T")).getTime();
      if (!Number.isNaN(ms)) draft[key] = v.trim().replace(" ", "T");
    }
  }
  return draft;
}

/** 解析模型输出为评估结果：容忍 markdown 围栏/前后缀文字，字段缺失时给安全默认。 */
export function parseEvalOutput(content: string): EvalResult {
  const start = content.indexOf("{");
  const end = content.lastIndexOf("}");
  if (start === -1 || end <= start) {
    throw new Error(`模型未返回 JSON: ${content.slice(0, 200)}`);
  }
  const out = JSON.parse(content.slice(start, end + 1)) as Record<string, unknown>;
  const priority: EvalPriority =
    typeof out.priority === "string" && EVAL_PRIORITIES.has(out.priority)
      ? (out.priority as EvalPriority)
      : "green";
  // N1：单条解析同样支持多草稿（取数组优先，兼容旧的单个 taskDraft）。
  const drafts = normalizeTaskDrafts(out.taskDrafts, out.taskDraft);
  return {
    priority,
    reason: typeof out.reason === "string" ? out.reason : "",
    taskDraft: drafts[0] ?? null,
    taskDrafts: drafts,
  };
}

// ---- v2.6.1 批量评估（省 Token：多条消息合并一次请求） ----

/** 上下文裁剪上限（与 mobile AiClient.titleMaxChars/bodyMaxChars 一致）。 */
export const EVAL_TITLE_MAX_CHARS = 100;
export const EVAL_BODY_MAX_CHARS = 500;

/** 按码点截断（Array.from；mobile 端按 grapheme cluster，差异仅限 emoji 组合序列边界）。 */
function truncate(text: string, max: number): string {
  const chars = Array.from(text);
  if (chars.length <= max) return text;
  return `${chars.slice(0, max).join("")}…（已截断）`;
}

/** 批量评估系统提示词（与 mobile _buildBatchSystemPrompt 逐字一致）：
 *  schema 为结果数组，元素按 messageId 对应输入消息。 */
export function buildEvalBatchSystemPrompt(
  registry: CategoryRegistry,
  customPrompt?: string,
): string {
  const catList = registry.categories
    .map(
      (c) =>
        `- ${c.key}（${c.displayName}）: ${c.description}` +
        `${c.priorityHints ? ` 优先级提示：${c.priorityHints}` : ""}`,
    )
    .join("\n");
  return appendCustomPrompt(
    `你是消息评估助手。用户消息里有「消息列表」，为其中每条消息输出一个评估对象，` +
      `整体组成一个 JSON 数组（顺序与输入一致）：\n` +
      `[{"messageId":"输入消息的 messageId","priority":"red|yellow|green|junk",` +
        `"reason":"一句话理由","taskDrafts":[` +
        `{"title":"...","description":"...","kind":"point|range","startAt":"YYYY-MM-DDTHH:mm",` +
        `"endAt":"YYYY-MM-DDTHH:mm","priority":"important|normal|minor"}]}]\n` +
        `priority 语义：red=重要、yellow=值得关注、green=一般、junk=垃圾（营销、推广、无用系统提示等）。` +
        `判断重要与垃圾是首要职责。结合来源应用与会话语境判断（如银行/支付类通知多重要、` +
        `应用商店的推广多为垃圾）。\n` +
        `taskDrafts 规则（数组，最多 3 个；没有可执行事项给空数组 []）：\n` +
        `- 一条消息里有多件互不相关的事，每件给一个草稿；同一件事的多个步骤仍只给一个草稿。\n` +
        `- 「值得留存备查」不构成建任务的理由；没有可执行动作就给空数组。\n` +
        `- title 不超过 20 个字符（中文按 2 字符计），超长的细节放入 description。\n` +
        `- kind=point 时点任务只需 startAt；kind=range 时段任务需要 startAt 和 endAt；` +
        `没有明确时间的可执行事项省略 startAt/endAt（不定时任务）。\n` +
        `- 同一件事的多步骤在主事项草稿里用换行列表写进 description；互不相关的事才拆成多个草稿。\n` +
        `- 任务 priority：important=重要、normal=一般、minor=不重要。\n` +
        `时间用本地时间字符串 "YYYY-MM-DDTHH:mm" 输出（不要自行换算毫秒），相对日期（如"本周五""下周一"）` +
        `查用户消息里的日期对照表确定；解析出的时间必须晚于基准时间：若字面日期标注了"已过去"，顺延到下一个未来的同名日期。\n` +
        `分类参考（辅助判断重要性与垃圾）：\n${catList}\n` +
        `只输出 JSON 数组。`,
    customPrompt,
  );
}

/** 批量用户消息（与 mobile _buildBatchUserContent 一致）：基准时间 + 日期对照表 +
 *  消息列表（标题/正文已按上限截断）。 */
export function buildEvalBatchUserContent(
  messages: ProcessInputMessage[],
  now: number,
): string {
  const weekChars = "日一二三四五六";
  const fmt = (d: Date) =>
    `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日（周${weekChars[d.getDay()]}）` +
    ` ${d.getHours()}:${String(d.getMinutes()).padStart(2, "0")}`;
  return JSON.stringify({
    基准时间: fmt(new Date(now)),
    日期对照表: buildDateHints(now),
    消息列表: messages.map((m) => ({
      messageId: m.id,
      消息时间: fmt(new Date(m.postedAt)),
      来源应用: m.appName ?? null,
      会话: m.conversationTitle ?? null,
      发送者: m.sender ?? null,
      标题: truncate(m.title, EVAL_TITLE_MAX_CHARS),
      正文: truncate(m.body, EVAL_BODY_MAX_CHARS),
    })),
  });
}

/** 解析批量评估输出：取首个 [ 到末个 ] 的 JSON 数组，按 messageId 建 map。
 *  容忍 markdown 围栏/前后缀文字；缺 messageId 或 id 不在批次内的元素忽略；
 *  完全没有合法数组时抛错（整批报错）。 */
export function parseEvalBatchOutput(
  messages: ProcessInputMessage[],
  content: string,
): Map<string, EvalResult> {
  const start = content.indexOf("[");
  const end = content.lastIndexOf("]");
  if (start === -1 || end <= start) {
    throw new Error(`模型未返回 JSON 数组: ${content.slice(0, 200)}`);
  }
  const arr = JSON.parse(content.slice(start, end + 1)) as unknown;
  if (!Array.isArray(arr)) {
    throw new Error(`模型输出不是 JSON 数组: ${content.slice(0, 200)}`);
  }
  const known = new Set(messages.map((m) => m.id));
  const results = new Map<string, EvalResult>();
  for (const item of arr) {
    if (!item || typeof item !== "object") continue;
    const o = item as Record<string, unknown>;
    const id = o.messageId;
    if (typeof id !== "string" || !known.has(id)) continue;
    const priority: EvalPriority =
      typeof o.priority === "string" && EVAL_PRIORITIES.has(o.priority)
        ? (o.priority as EvalPriority)
        : "green";
    // N1：优先读 taskDrafts 数组，兼容旧的单个 taskDraft。
    const drafts = normalizeTaskDrafts(o.taskDrafts, o.taskDraft);
    results.set(id, {
      priority,
      reason: typeof o.reason === "string" ? o.reason : "",
      taskDraft: drafts[0] ?? null,
      taskDrafts: drafts,
    });
  }
  return results;
}

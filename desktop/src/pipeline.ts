import { createHash } from "node:crypto";
import { Ajv2020 } from "ajv/dist/2020.js";
import type { ValidateFunction } from "ajv";
import type { AIProvider } from "./ai/provider.js";
import type { Store } from "./store.js";
import type {
  CategoryRegistry,
  GenericField,
  Priority,
  ProcessEvent,
  ProcessInputMessage,
  RawMessage,
  StructuredItem,
} from "./types.js";

const PRIORITIES = new Set(["P0", "P1", "P2", "P3"]);

const ajv = new Ajv2020({ allErrors: true, strict: false });
const validatorCache = new Map<string, ValidateFunction>();

/** 按注册表中该分类的 payloadSchema 编译校验器；generic 类的 $ref 指向注册表 definitions。 */
function getPayloadValidator(registry: CategoryRegistry, categoryKey: string): ValidateFunction | null {
  const cat = registry.categories.find((c) => c.key === categoryKey);
  if (!cat) return null;
  const cacheKey = `${registry.version}:${categoryKey}`;
  let validator = validatorCache.get(cacheKey);
  if (!validator) {
    const schema: Record<string, unknown> = { ...cat.payloadSchema };
    if (registry.definitions) schema.definitions = registry.definitions;
    validator = ajv.compile(schema);
    validatorCache.set(cacheKey, validator);
  }
  return validator;
}

/** 校验失败降级时，把原 payload 平铺为 generic 的 fields。 */
function flattenToFields(payload: Record<string, unknown>): GenericField[] {
  return Object.entries(payload).map(([key, value]) => ({
    key,
    value:
      typeof value === "object" && value !== null && !Array.isArray(value)
        ? JSON.stringify(value)
        : (value as GenericField["value"]),
    valueType: Array.isArray(value)
      ? ("list" as const)
      : typeof value === "number"
        ? ("number" as const)
        : typeof value === "boolean"
          ? ("boolean" as const)
          : ("string" as const),
  }));
}

// ---- 相似标题归并（char bigram Jaccard） ----

function bigrams(s: string): Set<string> {
  const t = s.toLowerCase().replace(/\s+/g, "");
  const set = new Set<string>();
  if (t.length === 1) set.add(t);
  for (let i = 0; i < t.length - 1; i++) set.add(t.slice(i, i + 2));
  return set;
}

function similarity(a: string, b: string): number {
  const A = bigrams(a);
  const B = bigrams(b);
  if (A.size === 0 || B.size === 0) return 0;
  let inter = 0;
  for (const x of A) if (B.has(x)) inter++;
  return (2 * inter) / (A.size + B.size);
}

/** 归并到已累计结果：仅当标题与内容都高度相似才归并（群聊折叠通知拆开后
 *  标题都是群名，只看标题会把毫不相关的消息绑在一起）。命中返回 true。 */
function mergeInto(accumulated: StructuredItem[], item: StructuredItem, warnings: string[]): StructuredItem | null {
  const existing = accumulated.find(
    (o) =>
      o.category === item.category &&
      similarity(o.title, item.title) >= 0.8 &&
      similarity(o.summary ?? "", item.summary ?? "") >= 0.5,
  );
  if (!existing) return null;
  existing.rawMessageIds = [...new Set([...existing.rawMessageIds, ...item.rawMessageIds])];
  warnings.push(`已归并相似消息：「${item.title}」并入「${existing.title}」（${item.category}）`);
  return existing;
}

// ---- 管线 ----

export interface PipelineResult {
  results: StructuredItem[];
  processedMessageIds: string[];
  failedMessageIds: string[];
  warnings: string[];
}

export interface PipelineOptions {
  /** 用户自定义提示词，透传给 AI provider */
  customPrompt?: string;
  /** 强制重新处理的消息 ID：这些消息跳过去重 */
  reprocessMessageIds?: string[];
  /** 每条消息处理完（或找回/失败）立即回调一次，供流式响应与增量落盘 */
  onProgress?: (event: ProgressEvent) => void;
}

/** 每条消息处理完（或找回/失败）立即回调一次，供流式响应与增量落盘。 */
export interface ProgressEvent {
  item?: StructuredItem;
  processedMessageIds: string[];
  failedMessageIds?: string[];
  warnings?: string[];
}

/** 内容去重键：不含 postedAt，应用重投/折叠产生的同内容消息可直接找回既有结果。 */
function contentKey(msg: RawMessage): string {
  return createHash("sha256")
    .update(`${msg.source.packageName}|${msg.title}|${msg.body}`)
    .digest("hex");
}

function dedupKeys(msg: RawMessage): string[] {
  return [msg.contentHash, contentKey(msg)];
}

/**
 * 逐条处理、逐条落盘、逐条回调（流式）：
 * 1. 去重（contentHash + 内容键；reprocessMessageIds 豁免），重复消息找回既有结果立即返回；
 * 2. 每条消息独立调 provider 分类+抽取，随后优先级回退、payload 校验降级、归并进已累计结果；
 * 3. 每条处理完立即写入 store 并触发 onProgress——连接中断只丢失正在处理的那一条。
 */
export async function runPipeline(
  messages: RawMessage[],
  registry: CategoryRegistry,
  provider: AIProvider,
  store?: Store,
  options: PipelineOptions = {},
): Promise<PipelineResult> {
  const warnings: string[] = [];
  const emit = options.onProgress ?? (() => undefined);

  // 1. 去重（本批内 + 历史已处理）。重复消息不直接丢弃——通过 hash→条目 映射找回之前
  //    生成的结果一并返回，否则"手机超时重试"场景下手机标记已处理却永远拿不到结构化结果。
  const reprocess = new Set(options.reprocessMessageIds ?? []);
  const fresh: RawMessage[] = [];
  const processedIds: string[] = [];
  const failedIds: string[] = [];
  const recovered: StructuredItem[] = [];
  const seen = new Set<string>();
  let dupCount = 0;
  for (const msg of messages) {
    const keys = dedupKeys(msg);
    const isDup =
      keys.some((k) => seen.has(k)) || (store ? keys.some((k) => store.hasHash(k)) : false);
    if (!reprocess.has(msg.id) && isDup) {
      dupCount++;
      processedIds.push(msg.id);
      const found = store
        ? [
            ...new Map(
              keys.flatMap((k) => store.findItemsByHash(k)).map((i) => [i.id, i] as const),
            ).values(),
          ]
        : [];
      for (const item of found) {
        if (!recovered.some((r) => r.id === item.id)) recovered.push(item);
        emit({ item, processedMessageIds: [msg.id] });
      }
      if (found.length === 0) emit({ processedMessageIds: [msg.id] });
      continue;
    }
    for (const k of keys) seen.add(k);
    fresh.push(msg);
  }
  if (dupCount > 0)
    warnings.push(
      `${dupCount} 条消息内容重复，已按已处理跳过` +
        (recovered.length > 0 ? `（找回既有结果 ${recovered.length} 条）` : ""),
    );

  // 2. 逐条 AI 处理 + 后处理 + 落盘 + 回调
  const accumulated: StructuredItem[] = [];
  for (const msg of fresh) {
    let items: StructuredItem[];
    try {
      items = await provider.process([msg], registry, { customPrompt: options.customPrompt });
    } catch (err) {
      failedIds.push(msg.id);
      const w = `AI provider (${provider.name}) 处理失败：${String(err)}`;
      warnings.push(w);
      emit({ processedMessageIds: [], failedMessageIds: [msg.id], warnings: [w] });
      continue;
    }

    const msgWarnings: string[] = [];
    const produced: StructuredItem[] = [];
    const newItems: StructuredItem[] = [];
    for (const item of items) {
      // 优先级回退
      const catDef = registry.categories.find((c) => c.key === item.category);
      if (!PRIORITIES.has(item.priority as string)) {
        item.priority = (catDef?.defaultPriority ?? "P2") as Priority;
        msgWarnings.push(`「${item.title}」缺少有效优先级，已用注册表默认值 ${item.priority}`);
      }
      // payload 校验，失败降级 generic
      const validator = catDef ? getPayloadValidator(registry, item.category) : null;
      const valid = validator ? validator(item.payload) : false;
      if (!valid) {
        const reason = validator ? ajv.errorsText(validator.errors) : `未知分类 ${item.category}`;
        const originalCategory = item.category;
        item.payload = {
          fields: [
            ...flattenToFields(item.payload),
            { key: "原始分类", value: originalCategory, valueType: "string" },
          ],
        };
        item.category = "generic";
        msgWarnings.push(`「${item.title}」payload 校验失败（${reason}），已降级为 generic`);
      }
      // 归并进已累计结果（标题+内容双相似）
      const merged = mergeInto(accumulated, item, msgWarnings);
      if (merged) {
        produced.push(merged); // 并入既有条目：不重复落盘，但把更新后的既有条目随事件送出
      } else {
        accumulated.push(item);
        newItems.push(item);
        produced.push(item);
      }
    }
    warnings.push(...msgWarnings);

    const covered = items.some((i) => i.rawMessageIds.includes(msg.id));
    const ids = covered ? [msg.id] : [];
    if (covered) processedIds.push(msg.id);
    else failedIds.push(msg.id);

    // 每条处理完立即落盘：连接中断时已完成的部分不丢
    if (store) {
      const pairs: Array<{ hash: string; itemId: string }> = [];
      for (const item of produced) {
        for (const k of dedupKeys(msg)) pairs.push({ hash: k, itemId: item.id });
      }
      store.recordHashItems(pairs);
      store.addHashes(dedupKeys(msg));
      store.appendItems(newItems);
    }

    if (produced.length === 0) {
      emit({
        processedMessageIds: ids,
        failedMessageIds: covered ? [] : [msg.id],
        warnings: msgWarnings,
      });
    } else {
      produced.forEach((item, idx) =>
        emit({
          item,
          processedMessageIds: idx === 0 ? ids : [],
          failedMessageIds: idx === 0 && !covered ? [msg.id] : [],
          warnings: idx === 0 ? msgWarnings : [],
        }),
      );
    }
  }

  return {
    results: [...recovered, ...accumulated],
    processedMessageIds: processedIds,
    failedMessageIds: failedIds,
    warnings,
  };
}

// ---- v2 流式评估（设计 §8.3，/v1/process 的管线） ----

export interface ProcessStreamingOptions {
  customPrompt?: string;
  /** 手机端"现在"（毫秒），日期对照表基准 */
  now: number;
  /** 每个事件（token/result/error）立即回调，由 server 逐行写入 NDJSON 流 */
  onEvent?: (event: ProcessEvent) => void;
}

/**
 * 逐条流式评估：每条消息独立调 provider.evaluateStreaming，token 逐段透传、
 * 结果/失败逐条回调；单条失败不影响后续消息。不落盘（电脑端无业务数据，设计 §11）。
 */
export async function processStreaming(
  messages: ProcessInputMessage[],
  registry: CategoryRegistry,
  provider: AIProvider,
  options: ProcessStreamingOptions,
): Promise<{ total: number; failed: number }> {
  const emit = options.onEvent ?? (() => undefined);
  let failed = 0;
  for (const msg of messages) {
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

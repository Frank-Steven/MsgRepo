import { Ajv2020 } from "ajv/dist/2020.js";
import type { ValidateFunction } from "ajv";
import type { AIProvider } from "./ai/provider.js";
import type { Store } from "./store.js";
import type {
  CategoryRegistry,
  GenericField,
  Priority,
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

function mergeSimilar(items: StructuredItem[], warnings: string[]): StructuredItem[] {
  const out: StructuredItem[] = [];
  for (const item of items) {
    const existing = out.find(
      (o) => o.category === item.category && similarity(o.title, item.title) >= 0.8,
    );
    if (existing) {
      existing.rawMessageIds = [...new Set([...existing.rawMessageIds, ...item.rawMessageIds])];
      warnings.push(`已归并相似消息：「${item.title}」并入「${existing.title}」（${item.category}）`);
    } else {
      out.push(item);
    }
  }
  return out;
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
  /** 强制重新处理的消息 ID：这些消息跳过 contentHash 去重 */
  reprocessMessageIds?: string[];
}

/**
 * 1. contentHash 去重（reprocessMessageIds 中的消息豁免）；2. provider 分类+抽取；
 * 3.（provider 内）相对时间→绝对毫秒；4. 优先级缺省回退注册表 defaultPriority；
 * 5. ajv 校验 payload，失败降级 generic；6. 相似消息归并。
 */
export async function runPipeline(
  messages: RawMessage[],
  registry: CategoryRegistry,
  provider: AIProvider,
  store?: Store,
  options: PipelineOptions = {},
): Promise<PipelineResult> {
  const warnings: string[] = [];

  // 1. 去重（本批内 + 历史已处理；reprocessMessageIds 豁免，处理后仍记 hash 保持幂等）。
  //    关键：重复消息不直接丢弃——通过 hash→条目 映射找回之前生成的结果一并返回，
  //    否则"手机超时重试"场景下手机标记已处理却永远拿不到结构化结果。
  const reprocess = new Set(options.reprocessMessageIds ?? []);
  const fresh: RawMessage[] = [];
  const dupIds: string[] = [];
  const recovered: StructuredItem[] = [];
  const recoveredIds = new Set<string>();
  const seen = new Set<string>();
  for (const msg of messages) {
    if (!reprocess.has(msg.id) && (seen.has(msg.contentHash) || store?.hasHash(msg.contentHash))) {
      dupIds.push(msg.id);
      if (store) {
        for (const item of store.findItemsByHash(msg.contentHash)) {
          if (!recoveredIds.has(item.id)) {
            recoveredIds.add(item.id);
            recovered.push(item);
          }
        }
      }
      continue;
    }
    seen.add(msg.contentHash);
    fresh.push(msg);
  }
  if (dupIds.length > 0)
    warnings.push(
      `${dupIds.length} 条消息 contentHash 重复，已按已处理跳过` +
        (recovered.length > 0 ? `（找回既有结果 ${recovered.length} 条）` : ""),
    );

  // 2. AI 分类 + 抽取
  let items: StructuredItem[];
  try {
    items = await provider.process(fresh, registry, { customPrompt: options.customPrompt });
  } catch (err) {
    return {
      results: recovered,
      processedMessageIds: [...dupIds],
      failedMessageIds: fresh.map((m) => m.id),
      warnings: [...warnings, `AI provider (${provider.name}) 处理失败：${String(err)}`],
    };
  }

  const covered = new Set(items.flatMap((i) => i.rawMessageIds));
  const failedMessageIds = fresh.filter((m) => !covered.has(m.id)).map((m) => m.id);

  // 4 + 5. 优先级回退 / payload 校验降级
  let degraded = 0;
  for (const item of items) {
    const catDef = registry.categories.find((c) => c.key === item.category);
    if (!PRIORITIES.has(item.priority as string)) {
      item.priority = (catDef?.defaultPriority ?? "P2") as Priority;
      warnings.push(`「${item.title}」缺少有效优先级，已用注册表默认值 ${item.priority}`);
    }
    const validator = catDef ? getPayloadValidator(registry, item.category) : null;
    const valid = validator ? validator(item.payload) : false;
    if (!valid) {
      const reason = validator ? ajv.errorsText(validator.errors) : `未知分类 ${item.category}`;
      degraded++;
      const originalCategory = item.category;
      item.payload = {
        fields: [
          ...flattenToFields(item.payload),
          { key: "原始分类", value: originalCategory, valueType: "string" },
        ],
      };
      item.category = "generic";
      warnings.push(`「${item.title}」payload 校验失败（${reason}），已降级为 generic`);
    }
  }
  if (degraded > 0) warnings.push(`${degraded} 条结果校验失败已降级为 generic`);

  // 6. 相似消息归并
  const results = mergeSimilar(items, warnings);

  if (store) {
    // 记录 消息 contentHash → 条目 id 映射（重处理时整体替换为新条目），供去重找回
    const hashByMsgId = new Map(messages.map((m) => [m.id, m.contentHash]));
    const pairs: Array<{ hash: string; itemId: string }> = [];
    for (const item of results) {
      for (const mid of item.rawMessageIds) {
        const h = hashByMsgId.get(mid);
        if (h) pairs.push({ hash: h, itemId: item.id });
      }
    }
    store.recordHashItems(pairs);
    store.addHashes(fresh.map((m) => m.contentHash));
    store.appendItems(results);
  }

  return {
    results: [...recovered, ...results],
    processedMessageIds: [...dupIds, ...fresh.filter((m) => covered.has(m.id)).map((m) => m.id)],
    failedMessageIds,
    warnings,
  };
}

// 与 shared/schemas/*.schema.json 对齐的 TS 类型。字段名以 schema 为唯一事实源。

export type Priority = "P0" | "P1" | "P2" | "P3";

export const SCHEMA_VERSION = "1.0.0";
export const PIPELINE_VERSION = "1.0.0";

// ---- raw-message.schema.json ----

export interface RawMessageSource {
  packageName: string;
  appName?: string;
  channelId?: string;
  conversationTitle?: string;
  sender?: string;
}

export interface RawMessageAttachment {
  id: string;
  kind: "image" | "file" | "miniprogram" | "link" | "other";
  label?: string;
  access: {
    type: "local_path" | "content_uri" | "url" | "app_deeplink" | "miniprogram_path";
    value: string;
    mimeType?: string;
  };
}

export interface RawMessage {
  id: string;
  source: RawMessageSource;
  title: string;
  body: string;
  postedAt: number;
  captureType: "notification" | "manual";
  attachments?: RawMessageAttachment[];
  contentHash: string;
  status: "pending" | "processed" | "archived";
}

// ---- structured-item.schema.json ----

export interface TimeInfo {
  kind: "none" | "point" | "range" | "deadline" | "recurring";
  startAt?: number;
  endAt?: number;
  deadline?: number;
  rrule?: string;
  reminderOffsets?: number[];
}

export interface StructuredItem {
  id: string;
  rawMessageIds: string[];
  category: string;
  schemaVersion: string;
  title: string;
  summary: string;
  priority: Priority;
  confidence: number;
  time: TimeInfo;
  payload: Record<string, unknown>;
  tags?: string[];
  processedBy: {
    provider: string;
    model?: string;
    pipelineVersion: string;
  };
}

// ---- category-registry.schema.json ----

export interface GenericField {
  key: string;
  value: string | number | boolean | unknown[];
  valueType?: "string" | "number" | "boolean" | "datetime" | "list";
}

export interface CategoryDef {
  key: string;
  displayName: string;
  description: string;
  baseKind: "specialized" | "generic";
  defaultPriority: Priority;
  priorityHints?: string;
  timeHints?: string;
  payloadSchema: Record<string, unknown>;
}

export interface CategoryRegistry {
  version: string;
  categories: CategoryDef[];
  definitions?: Record<string, unknown>;
}

// ---- sync-request / sync-response ----

export interface SyncRequest {
  deviceId: string;
  registryVersion: string;
  registry?: CategoryRegistry;
  customPrompt?: string;
  reprocessMessageIds?: string[];
  /** true 时以 application/x-ndjson 流式返回逐条进度 */
  stream?: boolean;
  messages: RawMessage[];
}

/** 流式同步的 NDJSON 事件：progress 每条消息一个（可多个，item 可选），done 收尾。 */
export interface SyncStreamEvent {
  type: "progress" | "warning" | "done";
  item?: StructuredItem;
  processedMessageIds?: string[];
  failedMessageIds?: string[];
  warnings?: string[];
  message?: string;
  registryVersion?: string;
}

export interface SyncResponse {
  registryVersion: string;
  results: StructuredItem[];
  processedMessageIds: string[];
  failedMessageIds?: string[];
  warnings?: string[];
}

// ---- v2 /v1/process（设计 §8、§12） ----

/** /v1/process 请求中的单条消息：手机端是数据权威，电脑端只做评估不回写。 */
export interface ProcessInputMessage {
  id: string;
  title: string;
  body: string;
  appName?: string;
  conversationTitle?: string;
  sender?: string;
  postedAt: number;
}

export interface ProcessRequestBody {
  messages: ProcessInputMessage[];
  customPrompt?: string;
  /** 手机端本地时间 ISO 字符串，作为日期对照表与"已过去顺延"的基准 */
  now: string;
  timezone?: string;
}

/** 消息优先级（设计 §1.1）：红=重要、黄=值得关注、绿=一般、junk=垃圾。 */
export type EvalPriority = "red" | "yellow" | "green" | "junk";

/** AI 评估产出的任务草稿（设计 §8.2）；时间字段为本地时间字符串 "YYYY-MM-DDTHH:mm"。 */
export interface TaskDraft {
  title: string;
  description?: string;
  kind: "point" | "range";
  startAt?: string;
  endAt?: string;
  priority: "important" | "normal" | "minor";
}

/** 单条消息的最终评估结果。 */
export interface EvalResult {
  priority: EvalPriority;
  reason: string;
  taskDraft: TaskDraft | null;
}

/** /v1/process 的 NDJSON 流式事件：token 为模型原始输出透传，result/error 每消息一条，done 收尾。 */
export type ProcessEvent =
  | { type: "token"; messageId: string; delta: string }
  | { type: "result"; messageId: string; priority: EvalPriority; reason: string; taskDraft: TaskDraft | null }
  | { type: "error"; messageId: string; error: string }
  | { type: "done"; total: number; failed: number };

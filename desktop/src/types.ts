// 与 shared/schemas/*.schema.json 对齐的 TS 类型。字段名以 schema 为唯一事实源。



// ---- raw-message.schema.json ----




// ---- structured-item.schema.json ----



// ---- category-registry.schema.json ----


/** 分类的默认优先级（v1 沿用，注册表与 AI 输出仍用 P0-P3 表示分类倾向）。 */
export type Priority = "P0" | "P1" | "P2" | "P3";

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


/** 流式同步的 NDJSON 事件：progress 每条消息一个（可多个，item 可选），done 收尾。 */


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
  /** 兼容字段：第一条草稿。 */
  taskDraft: TaskDraft | null;
  /** N1：一条消息可产出多个任务草稿（0..3）。 */
  taskDrafts?: TaskDraft[];
}

/** /v1/process 的 NDJSON 流式事件：token 为模型原始输出透传，result/error 每消息一条，done 收尾。 */
export type ProcessEvent =
  | { type: "token"; messageId: string; delta: string }
  | {
      type: "result";
      messageId: string;
      priority: EvalPriority;
      reason: string;
      taskDraft: TaskDraft | null;
      taskDrafts?: TaskDraft[];
    }
  | { type: "error"; messageId: string; error: string }
  | { type: "done"; total: number; failed: number };

// ---- task-anchor.schema.json（design-v3 §1.1）----

/** 任务锚点：连接一个任务与库中消息/笔记/文件；正文行内 marker 为 ⟦task:<id>⟧。 */
export interface TaskAnchor {
  id: string;
  taskId: string;
  targetType: "message" | "note" | "file";
  targetId: string;
  label?: string | null;
  createdBy: "user" | "ai";
  /** Unix 毫秒时间戳 */
  createdAt: number;
}

// ---- chat-request.schema.json（design-v3 §2、§6.3）----

export interface ChatMessageRef {
  type: "note" | "message" | "file";
  id: string;
}

export interface ChatRequestMessage {
  role: "user" | "assistant" | "tool";
  content: string;
  /** 该消息引用的库实体（仅引用）；正文在顶层 attachments 中展开 */
  attachments?: ChatMessageRef[];
}

/** 附件正文展开块：带 [#note:标题] 类引用头，供 AI 引用定位。 */
export interface ChatAttachment {
  type: "note" | "message" | "file";
  id: string;
  content: string;
}

export interface ChatRequest {
  conversationId: string;
  messages: ChatRequestMessage[];
  attachments?: ChatAttachment[];
  /** 对话绑定的模型配置 id，缺省用 defaultModelId */
  modelConfigId?: string;
  stream: boolean;
}

// ---- chat-response.schema.json（design-v3 §2、§5.4）----

/**
 * /v1/chat 流式事件。desktop 只透传 token 流、不解析不执行工具；
 * proposal 事件的 proposalId 由客户端（手机端解析层）生成。
 */
export type ChatEvent =
  | { type: "token_delta"; delta: string }
  | {
      type: "proposal";
      proposalId: string;
      /** 原子工具名，如 task.create（清单见 design-v3 §5.2） */
      tool: string;
      args: Record<string, unknown>;
    }
  | { type: "done" }
  | { type: "error"; error: string };

// ---- model-config.schema.json（design-v3 §6.2）----

/** 模型配置；Ollama 暂缓，provider 暂只列 openai-compat / mock。 */
export interface ModelConfig {
  id: string;
  name: string;
  provider: "openai-compat" | "mock";
  baseUrl: string;
  model: string;
  /** API key 所在环境变量名，不直接存密钥 */
  apiKeyEnv?: string;
}

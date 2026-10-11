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
  messages: RawMessage[];
}

export interface SyncResponse {
  registryVersion: string;
  results: StructuredItem[];
  processedMessageIds: string[];
  failedMessageIds?: string[];
  warnings?: string[];
}

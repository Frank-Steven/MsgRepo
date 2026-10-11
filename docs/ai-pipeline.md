# AI 处理管线

电脑端把一批 RawMessage 变成 StructuredItem 的完整流程。实现在 `desktop/src/pipeline.ts` 与 `desktop/src/ai/`。

## 管线总览

管线**逐条处理、逐条落盘、逐条回调**（流式，见 `docs/protocol.md`）：每条消息独立走完
2–6 步后立即写入 `items.jsonl` 并触发 `onProgress`（流式同步时逐条下发给手机），
连接中断只丢失正在处理的那一条。

```
RawMessage[]
  │
  ├─ 1. 预处理        双重去重：contentHash（含 postedAt）+ 内容键
  │                    sha256(packageName|title|body)（不含时间，应用重投/
  │                    折叠更新的同内容消息直接命中）；重复消息通过 hash→条目
  │                    映射找回既有结果立即返回，不再调用模型
  │
  ├─ 2. 分类+抽取      AIProvider.process([msg], registry)（逐条调用）
  │     │              提示词由注册表动态生成（见下）
  │     │              输出 generic 时自动发起第二次强势分类（见下）
  │     ▼
  ├─ 3. 时间归一       相对时间 → 绝对毫秒（基准 = 消息的 postedAt）
  │                    填入统一的 time 结构
  │
  ├─ 4. 优先级修正     AI 初判 → 注册表 defaultPriority 兜底
  │
  ├─ 5. 校验与降级     payload 过注册表 payloadSchema（ajv）
  │                    失败 → category=generic + 平铺 fields + warning
  │
  └─ 6. 归并          并入本批已累计结果：要求**标题相似度 ≥0.8 且
                     内容摘要相似度 ≥0.5**（折叠通知拆开后标题都是群名，
                     只看标题会把不相关消息绑在一起）
  │
  ▼
StructuredItem[]（每条产出时即落盘 + onProgress 回调）
```

## 提示词策略

AI 分类准确的根本手段是：**提示词由注册表动态生成，而不是写死在代码里。**

发给模型的系统提示词包含：

1. **任务说明**：你是通知分类器，对每条消息输出 category + payload + priority + time + confidence；
2. **分类清单**：遍历注册表，每个分类给出 `key`、`displayName`、`description`（含典型措辞）、`priorityHints`、`timeHints`、`payloadSchema`；
3. **时间基准**：每条消息的 `postedAt` 换算成可读时间随消息一起给出，要求模型把"明天下午三点"这类表达直接输出为 Unix 毫秒；
4. **输出约束**：结构化输出（Ollama 的 `format` 参数 / OpenAI 兼容的 `response_format`），schema 即 StructuredItem 信封 + 各分类 payload 的并集；
5. **降级指引**：拿不准就输出 `generic`，并给低 confidence，禁止编造。

### generic 二次分类

`generic` 是兜底而非首选。openai-compatible provider 在首次输出为 `generic` 时会自动发起第二次请求：提示词强调"generic 是最后手段，必须在具体分类中选最贴近的一个"。二次仍返回 generic 才接受，并把 confidence 压到 ≤0.4，由手机端 UI 标记"待确认"。实测这能把本地小模型的"惰性兜底"（稍模糊就往 generic 放）减少大半。

### payloadSchema 的 $ref 必须内联

发给模型的 payloadSchema 若含 `"$ref": "#/definitions/genericField"`，**必须把注册表的 `definitions` 一并附进提示词**——模型看不到引用目标时只能猜字段名（实测猜成 `name` 而非 `key`，导致 payload 校验失败降级）。代码中由 provider 序列化 schema 时自动内联，注册表作者无需关心。

因此**写好注册表里的 description/hints 就是调优分类质量的主要手段**，无需改代码。新增分类后提示词自动包含它。

## AIProvider 适配层

```ts
interface AIProvider {
  readonly name: string;
  process(messages: RawMessage[], registry: CategoryRegistry): Promise<StructuredItem[]>;
}
```

三个实现：

| Provider | 用途 | 要点 |
|---|---|---|
| `mock` | 无模型环境跑通全链路、单元测试 | 纯规则引擎：关键词匹配分类 + 正则抽取（验证码 4-8 位数字、取件码、金额、中文相对时间） |
| `ollama` | 本地模型主力 | `POST /api/chat`，`format` 传 JSON Schema 约束输出；建议模型：qwen3:8b 及以上 |
| `openai-compatible` | 任何 OpenAI 兼容端点（llama.cpp server、LM Studio、vLLM 等） | `POST /chat/completions`；优先 `response_format=json_object`，端点不支持（400）时自动降级为纯 prompt 约束；输出容忍 markdown 围栏/前后缀文字 |

配置在 `desktop/config/default.json`（provider、baseUrl、model、超时）。切换 AI 服务不改代码。

## 时间解析

两类实现路径：

- **AI provider**：不让模型做日期/毫秒算术——实测本地模型（26B 级）直接输出毫秒时间戳几乎必错。改为：
  1. 基准时间以"含星期几的本地时间"可读形式给出；
  2. 附一张**日期对照表**（`buildDateHints`）：今天/明天/后天 + 本周一～日 + 下周一～日的具体日期，已过去的日期显式标注；
  3. 模型输出本地时间字符串 `"YYYY-MM-DDTHH:mm"`，由代码（`normalizeTime`）换算成毫秒；
  4. **顺延规则**：解析结果必须晚于基准时间，字面日期已过去则取下一个未来同名日期（周日收到"本周五开会"→ 下周五）。
- **mock provider**：内置正则处理常见中文时间表达：`今天/明天/后天`、`HH:mm`、`x 小时后`、`x 分钟内`、`M月d日`、`周X`，基准为 `postedAt`。

解析失败时 `time.kind = none`，绝不允许把解析不了的时间猜成一个具体时刻——错的时间提醒比没有提醒更糟。

## 降级与兜底

| 失败点 | 处理 |
|---|---|
| 模型超时/不可达 | 该批消息进 `failedMessageIds`，手机端保持 pending 下轮重试 |
| 输出不是合法 JSON | 同上 |
| category 不在注册表 | 强制改为 `generic`，warning 记录 |
| payload 不符合 schema | category 改 `generic`，原 payload 平铺进 fields，warning 记录 |
| confidence 低 | 不降级，UI 标记"待确认" |

原则：**宁可降级为 generic 保留全部信息，也不让整条消息丢失或处理中断。**

## 性能预期

- 批量处理：一次 sync 的消息合并为一个模型请求（提示词中编号），本地 8B 模型处理 50 条通知约 10–30 秒
- 超长正文截断至 2000 字符（通知正文极少超过）
- 验证码等 P0 消息未来可走"快速通道"（手机端本地正则直接提取，不等同步）——见 extensibility

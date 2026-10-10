# AI 处理管线

电脑端把一批 RawMessage 变成 StructuredItem 的完整流程。实现在 `desktop/src/pipeline.ts` 与 `desktop/src/ai/`。

## 管线总览

```
RawMessage[]
  │
  ├─ 1. 预处理        contentHash 去重；空内容/纯表情等规则过滤
  │
  ├─ 2. 分类+抽取      AIProvider.process(messages, registry)
  │     │              提示词由注册表动态生成（见下）
  │     ▼
  ├─ 3. 时间归一       相对时间 → 绝对毫秒（基准 = 消息的 postedAt）
  │                    填入统一的 time 结构
  │
  ├─ 4. 优先级修正     AI 初判 → 注册表 defaultPriority 兜底
  │
  ├─ 5. 校验与降级     payload 过注册表 payloadSchema（ajv）
  │                    失败 → category=generic + 平铺 fields + warning
  │
  └─ 6. 归并          同事件多条通知合并为一条 StructuredItem
                     （rawMessageIds 保留全部来源）
  │
  ▼
StructuredItem[]
```

## 提示词策略

AI 分类准确的根本手段是：**提示词由注册表动态生成，而不是写死在代码里。**

发给模型的系统提示词包含：

1. **任务说明**：你是通知分类器，对每条消息输出 category + payload + priority + time + confidence；
2. **分类清单**：遍历注册表，每个分类给出 `key`、`displayName`、`description`（含典型措辞）、`priorityHints`、`timeHints`、`payloadSchema`；
3. **时间基准**：每条消息的 `postedAt` 换算成可读时间随消息一起给出，要求模型把"明天下午三点"这类表达直接输出为 Unix 毫秒；
4. **输出约束**：结构化输出（Ollama 的 `format` 参数 / OpenAI 兼容的 `response_format`），schema 即 StructuredItem 信封 + 各分类 payload 的并集；
5. **降级指引**：拿不准就输出 `generic`，并给低 confidence，禁止编造。

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
| `openai-compatible` | 任何 OpenAI 兼容端点（llama.cpp server、LM Studio、vLLM 等） | `POST /chat/completions`，`response_format: {type:"json_object"}`，prompt 中内嵌 schema |

配置在 `desktop/config/default.json`（provider、baseUrl、model、超时）。切换 AI 服务不改代码。

## 时间解析

两类实现路径：

- **AI provider**：把 `postedAt` 的可读形式（含星期）写进每条消息的上下文，要求模型直接输出绝对毫秒；mock 之外的实现都走这条路；
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

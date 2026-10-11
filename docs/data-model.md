# 数据模型设计

> 这是 MsgRepo 最核心的设计文档。机器可校验的定义见 `shared/schemas/`（JSON Schema，唯一事实源），本文解释设计意图、语义与演进规则。代码与本文冲突时，以 `shared/schemas/` 为准并修订本文。

## 设计目标

1. **分类准确**：AI 分类所依据的"已有信息结构"必须与消息内容分离，可独立演进、可协商版本。
2. **高度可扩展**：新增一个分类不应要求修改两端代码。
3. **时间语义统一**：手机端做提醒调度时，不应理解每个分类各自的字段，只读一个统一的时间结构。
4. **降级安全**：AI 输出不合格时系统不能崩，也不能丢信息。
5. **附件即引用**：附件（图片/文件/小程序）只传访问方式，不传内容。

## 总体结构：三层模型

```
RawMessage（原始层，手机端产生）
    │  同步（POST /v1/sync，附 CategoryRegistry）
    ▼
StructuredItem（结构层，电脑端 AI 产生）── 统一信封 + 分类 payload
    │
    ▼
CategoryRegistry（元数据层，描述"有哪些分类、各自什么结构"）
```

三个概念分别对应三份 schema：`raw-message.schema.json`、`structured-item.schema.json`、`category-registry.schema.json`。同步请求/响应的包装见 `sync-request.schema.json` / `sync-response.schema.json`。

---

## 1. RawMessage —— 原始消息

手机端采集的最小信息单元，忠实地保留原始内容，不做任何理解。

| 字段 | 说明 |
|---|---|
| `id` | UUID v4，手机端生成，全局唯一 |
| `source` | 来源：`packageName` / `appName` / `channelId` / `conversationTitle` / `sender` |
| `title` / `body` | 通知标题与正文（或手动输入） |
| `postedAt` | 消息发出的 Unix 毫秒。**AI 解析"明天下午三点"等相对时间时必须以此为基准**，不能用处理时刻 |
| `captureType` | `notification`（系统采集）/ `manual`（手动添加） |
| `attachments[]` | 附件，**只存访问方式**：`access.type` ∈ `local_path` / `content_uri` / `url` / `app_deeplink` / `miniprogram_path` |
| `contentHash` | `SHA-256(packageName\|title\|body\|postedAt)`，两端去重的依据 |
| `status` | `pending` → `processed` →（可选）`archived` |

设计要点：

- **采集前过滤**：是否收集某应用的通知由手机端应用过滤器（`all` / `allowlist` 模式）在采集层决定，被拦截的通知不会成为 RawMessage。过滤回答"收不收"，注册表分类回答"算什么"，两者正交。
- **附件即引用**。图片/文件可能很大，小程序根本无法导出内容；统一存"访问方式"让同步消息保持轻量，也让 AI 只处理文本。AI 若需要查看某张图片，属于未来的多模态扩展，协议已预留（附件有 `id`，可增加"按需拉取附件内容"端点）。
- `postedAt` 进入哈希，同一条通知重发（如倒计时更新）会被视为新消息——由电脑端管线的"归并"步骤处理重复事件，而不是在手机端激进丢弃。

## 2. StructuredItem —— 结构化结果（统一信封）

电脑端 AI 的输出。所有分类共用一个信封，差异收敛到 `payload`：

```
┌─ 信封（所有分类一致）─────────────────────────┐
│ id / rawMessageIds[] / category / schemaVersion │
│ title / summary                                │
│ priority: P0–P3                                │
│ confidence: 0–1                                │
│ time: { kind, startAt, endAt, deadline,        │
│         rrule, reminderOffsets }               │
│ tags[] / processedBy                           │
├─ payload（按 category 的 payloadSchema 校验）──┤
│ schedule → { event, location, ... }            │
│ todo     → { task, subtasks, status, ... }     │
│ generic  → { fields: [{key, value, valueType}] }│
└────────────────────────────────────────────────┘
```

### 2.1 为什么用"统一信封 + 分类载荷"而不是多态类型

- 手机端的**展示框架、提醒调度、优先级排序**只依赖信封，新增分类零改动；
- `payload` 的合法性由注册表中的 `payloadSchema` 约束，schema 存在注册表里而不是代码里——**分类体系是数据，不是代码**。

### 2.2 统一时间结构 `time`

提醒功能的基石。五种 `kind`：

| kind | 语义 | 必填字段 | 提醒基准 |
|---|---|---|---|
| `none` | 无时间信息 | — | 不调度 |
| `point` | 某一时刻发生 | `startAt` | `startAt` |
| `range` | 起止区间（会议、航班） | `startAt`, `endAt` | `startAt` |
| `deadline` | 截止时刻（缴费、取件） | `deadline` | `deadline` |
| `recurring` | 周期重复 | `rrule`（RFC 5545） | 按 rrule 展开（骨架版仅提示不支持调度） |

`reminderOffsets`（分钟列表，如 `[60, 10]`）表示相对提醒基准提前多久提醒。手机端调度本地通知的算法：`提醒时刻 = 基准时刻 − offset × 60s`，对每个 offset 各排一条。

**规则：任何分类的时间信息都必须归一到 `time`，payload 里不再单独存时间。** 这样手机端提醒模块永远不需要知道"日程的开始时间字段叫什么"。

### 2.3 优先级 P0–P3

| 级别 | 语义 | 典型 |
|---|---|---|
| P0 | 紧急且时间敏感，应立即提醒 | 验证码、即将开始的会议、临近的最后期限 |
| P1 | 重要，需要在合理时间内看到 | 账单、待取快递、近期日程 |
| P2 | 普通（默认） | 一般待办、普通消息 |
| P3 | 低价值，可折叠/归档 | 营销推送、笔记 |

优先级由 AI 初判，注册表中每个分类的 `priorityHints` 给 AI 判定指引，`defaultPriority` 做兜底。

### 2.4 置信度与人工确认

`confidence < 阈值（建议 0.6）` 的条目，手机端 UI 标记"待确认"。这不是可选项而是信任机制：本地小模型必然犯错，显式暴露不确定性比默默分类错误好。

### 2.5 归并

`rawMessageIds` 是数组：同一事件的多条通知（如"快递运输中→派送中→到达"）应归并为一条 StructuredItem，保留全部来源 ID 以便溯源。归并发生在电脑端管线最后一步。

## 3. CategoryRegistry —— 分类注册表（可扩展性核心）

注册表回答一个问题：**"现在有哪些分类，每个分类长什么样？"** 它只含结构与描述，绝不含消息内容。

### 3.1 两类分类

- **specialized（特殊化结构）**：内置 `schedule` / `todo` / `note`，payload 是固定 JSON Schema，字段语义明确，两端 UI 可以做专门渲染（如待办的勾选框）。这类分类结构稳定，数量刻意保持很少。
- **generic（通用结构）**：payload 统一为 `{ fields: [{key, value, valueType}] }`——一张键值表。在其之上，注册表可以声明任意多个"轻量分类"（内置了 `express` 快递 / `bill` 账单 / `coupon` 优惠 / `verification` 验证码），每个只是一段描述 + 默认规则。**新增一个轻量分类 = 在注册表 JSON 里加一个对象，两端代码零改动。**

通用结构刻意做成"简易方便"：key-value 表对 AI 容易生成、对人类容易读、对 UI 容易渲染（逐行显示即可）。它牺牲了强类型，换来无限扩展性——这正是与 specialized 的分工：高频刚需分类享受强类型，长尾分类走通用通道。

### 3.2 注册表如何帮助"分类准确"

同步时手机把当前注册表发给电脑，AI 的提示词由注册表**动态生成**：每个分类的 `description`（含典型措辞样例）、`priorityHints`、`timeHints` 都成为提示词的一部分。这就是需求中"已有处理后的信息结构（不含具体内容，只是为了分类准确）"的实现方式——**注册表是两端之间关于"如何理解消息"的共享知识**。

因此写注册表时：`description` 要写给 AI 看，包含典型措辞，比写给人类看更重要。

### 3.3 版本协商

注册表带语义化 `version`。同步协议中的协商规则：

1. 请求携带 `registryVersion`；若与电脑端一致，省略 `registry` 体；
2. 不一致时请求携带完整 `registry`，电脑端采用请求中的版本并持久化（手机是注册表的权威来源，因为它是用户的入口）；
3. 响应回传电脑端实际使用的 `registryVersion`，供手机端确认。

注意区分两个版本：`CategoryRegistry.version`（分类体系演进）与 `StructuredItem.schemaVersion`（信封结构演进），互相独立。

### 3.4 降级规则

AI 输出的 `payload` 必须通过该分类的 `payloadSchema` 校验。失败时：

1. `category` 改为 `generic`；
2. 原 payload 平铺进 `fields`（每个键变成一个 field），**信息不丢**；
3. 响应 `warnings` 记录降级原因，便于排查是提示词问题还是注册表定义问题。

`confidence` 过低不算校验失败，不触发降级，只在 UI 标记待确认。

## 4. 端到端数据流示例

```
[手机] 银行 App 通知：「您本期信用卡账单 ¥1,280.50，最后还款日 10月25日」
  → RawMessage { source: {packageName: "com.bank.app"}, title: "账单提醒",
                 body: "...", postedAt: 1760054400000, status: "pending" }
  → adb reverse 建立连接，POST /v1/sync（附注册表 v1.0.0）
[电脑] 管线：去重 → Mock/Ollama 分类为 bill → 抽取金额与日期
  → 时间解析：「10月25日」以 postedAt 为基准 → deadline: 1761321599000
  → 优先级：priorityHints「临近最后期限 P0」→ 距今 14 天 → P1
  → payload 通过 bill 的 fields schema 校验
[手机] ← SyncResponse { results: [StructuredItem {
           category: "bill", priority: "P1",
           time: { kind: "deadline", deadline: 1761321599000,
                   reminderOffsets: [1440, 120] },
           payload: { fields: [{key:"金额", value:1280.50, valueType:"number"},
                               {key:"机构", value:"XX银行"}] } }],
         processedMessageIds: ["<原消息 id>"] }
  → 原消息 status = processed
  → 提醒调度：deadline 前 1440 分钟（前一天）和前 120 分钟各一条本地通知
  → 收件箱中该条显示为「账单缴费 · P1 · 10月25日截止」
```

## 5. 演进规则（改模型时必读）

1. **加字段**：信封加可选字段，schemaVersion 不变；加必填字段，schemaVersion 升主版本，两端同时发布。
2. **加分类**：优先在注册表加 generic 轻量分类（零代码）；当一个 generic 分类被证明高频且需要专门 UI 时，才提升为 specialized（信封不变，payloadSchema 强化）。
3. **改时间语义**：禁止。`time` 的五种 kind 是封闭集合，新时间语义应映射到现有 kind（如"每年生日"= recurring + rrule）。
4. **payload 里的 datetime**：一律 Unix 毫秒整数（generic fields 中 `valueType: datetime` 的 value 是毫秒字符串），禁止各分类自定义日期字符串格式。

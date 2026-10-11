# MsgRepo v2 设计文档

> 本文档是 MsgRepo 的现行设计（v2），取代 v1 系列文档（`architecture.md` / `data-model.md` 等，保留作历史参考）。
> 核心理念：**日程表与待办清单的结合是应用本体，消息只是数据源，AI 是可从手机端插拔的处理服务。**

## 0. 总览

```
┌──────────────────────────── 手机端（全部功能）────────────────────────────┐
│  日程(年/月/日三视图)  待办  笔记  消息(数据源)  设置                        │
│  ─────────────────────────────────────────────────────────────            │
│  SQLite(DB v4) · 撤销队列 · 提醒调度 · 通知采集 · AiClient(路由+流式)        │
└──────────────┬───────────────────────────────┬────────────────────────────┘
               │ adb reverse（自动建立）          │ HTTPS（用户配置的远程 API）
┌──────────────▼──────────────┐   ┌─────────────▼─────────────┐
│ 电脑端（纯 AI 服务）          │   │ 远程 OpenAI 兼容 API        │
│ 状态栏菜单应用（Electron）     │   │ （本地 llama.cpp 或其他）    │
│ AI 接口 + 服务管理器 + 自动通道│   └───────────────────────────┘
└─────────────────────────────┘
```

- **手机端**持有全部数据与全部 UI：任务、笔记、消息、撤销、提醒。
- **电脑端**只做三件事：提供流式 AI 接口、管理本地 AI 服务（模型启停/选择）、维护 adb 通道。无业务数据、无 dashboard。
- **AI 路由**：手机检测到电脑端在线（health 探测，30s 缓存）→ 用电脑端模型；否则用设置中配置的默认远程 API。两者都走 OpenAI 兼容协议 + SSE 流式。
- **零配置**：USB 物理通道即信任。电脑端只监听 loopback，手机端首次连通自动配对（`POST /v1/pair`），不输入 token。

## 1. 数据模型 v2（SQLite，DB v4）

### 1.1 messages —— 消息（数据源）

消息是**证据与上下文**，不是应用的主体。它只回答问题："这条信息从哪来、说了什么、重要吗、有没有衍生任务"。

```sql
CREATE TABLE messages(
  id TEXT PRIMARY KEY,
  package_name TEXT NOT NULL,          -- 来源应用包名；手动添加为 'manual'
  app_name TEXT,
  channel_id TEXT,
  conversation_title TEXT,             -- 会话标题（群名/联系人）
  sender TEXT,                         -- 拆分折叠通知后填充
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  posted_at INTEGER NOT NULL,
  capture_type TEXT NOT NULL,          -- notification | manual | import
  import_source TEXT,                  -- 预留：wechat | qq | sms
  attachments TEXT NOT NULL DEFAULT '[]',
  content_hash TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'pending',  -- pending | processed | archived
  priority TEXT NOT NULL DEFAULT 'none',   -- none | red | yellow | green | junk
  linked_task_id TEXT,                 -- 衍生任务（可空）
  created_at INTEGER NOT NULL
);
```

- `priority` 语义：**红=重要、黄=值得关注、绿=一般、junk=垃圾、none=未评估**。AI 处理时初判，用户可随时改。
- `status` 只管"是否流转过"：pending（未处理）→ processed（已评估，留在列表）→ archived（归档，移出主列表）。与 v1 的 done 合并进 archived。
- 消息**没有"完成"态**——完成是任务的概念。

### 1.2 tasks —— 任务（应用主体之一）

```sql
CREATE TABLE tasks(
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,                 -- 宽度约束见 §7.4
  description TEXT,
  kind TEXT NOT NULL,                  -- point | range
  start_at INTEGER,                    -- 可空 = 无时间任务（"我的待办"）
  end_at INTEGER,                      -- kind=range 时非空
  priority TEXT NOT NULL DEFAULT 'normal',  -- important | normal | minor
  is_annual INTEGER NOT NULL DEFAULT 0,     -- 年度任务（每年重复展示）
  source_message_id TEXT,              -- 来源消息（可空，任务可独立存在）
  status TEXT NOT NULL DEFAULT 'active',    -- active | done | archived
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_tasks_start ON tasks(start_at);
CREATE INDEX idx_tasks_status ON tasks(status);
```

- 五类派生展示（由 kind + 时间得出，不落库）：时间点 / 时间点任务 / 时间段 / 时间段任务 / 普通任务。在 v2 中统一为任务实体，`kind` + `start_at/end_at` 可空覆盖全部五类。
- `is_annual`：年度任务（如"年度体检"），在年视图与待办的"年度任务"分组中逐年展示；**不允许时间跨度跨一整年**（跨年任务拆成年度任务或分段）。
- 任务可以没有来源消息（`source_message_id` 可空）——手动创建与 AI 创建地位相同。

### 1.3 笔记三级

```sql
CREATE TABLE notebooks(
  id TEXT PRIMARY KEY, name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE TABLE chapters(
  id TEXT PRIMARY KEY, notebook_id TEXT NOT NULL REFERENCES notebooks(id),
  name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL
);
CREATE TABLE notes(
  id TEXT PRIMARY KEY, chapter_id TEXT NOT NULL REFERENCES chapters(id),
  title TEXT NOT NULL, content TEXT NOT NULL DEFAULT '',
  content_format TEXT NOT NULL DEFAULT 'plain',   -- plain；markdown 预留
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
```

### 1.4 撤销队列（内存，不落盘）

见 §6。重启后队列清空是可接受的——撤销窗口只有 10 秒。

### 1.5 从 DB v3 迁移

迁移只增不删，旧表（raw_messages / structured_items）原样保留一个版本周期：

| 旧 | 新 |
|---|---|
| raw_messages | → messages（status 保留；done→archived；priority 由 structured_items 的 priority 映射：P0/P1→red，P2→yellow，P3→green） |
| structured_items (category=todo/schedule) | → tasks（time.kind=point→kind=point+start_at；range/deadline→对应区间；payload.priority→三档映射；rawMessageIds[0]→source_message_id） |
| structured_items (category=note) | → 默认笔记本「导入」的章节「AI 笔记」下的 notes |
| structured_items (其他) | 不迁移实体，仅在 messages.priority 上留评估结果 |

## 2. 模块一：日程（首屏，核心）

三个粒度视图共用一套渲染思想：**泳道 + 节点/线段 + 名称层**，全部 CustomPainter 自绘 + GestureDetector 交互。

### 2.1 年视图

- 布局：4 行（每季度一行）× 3 块（每块一个月）。月块等宽，块间距固定。
- 泳道：每月块内 3 条水平泳道，**月与月之间上下对齐**；从上到下依次为 **红(important) → 黄(normal) → 绿(minor)**。
- 任务表示：
  - 月级任务（起点终点同月或仅指定月）→ 该月泳道上的**节点**（圆点）。
  - 跨月任务 → **带端点节点的线段**，跨越其覆盖的月块。
  - 任务名称在节点/线段**右侧横向**显示（放得下才显示，放不下省略）。
  - **当前月高亮**（底色 + 边框）。
- 填充算法（泳道内，纯函数 `layoutYearLane(tasks)`）：
  1. 泳道内任务按开始时间先后排序；
  2. 单条泳道纵向可叠多个"槽位"：任务按开始时间从上到下填补空位；
  3. 若某槽位被更早的跨月任务线段占据，**跳过该位置继续往下排**（跨月任务优先占位）；
  4. 跨月任务起点或终点不在当前年：端点处画**延伸样式**（斜切箭头指出边界），但**不为跨年保留槽位**——下一年的该任务直接排其优先级泳道的最上面槽位。
- 交互：
  - 点击月块 → 下钻到该月的月视图；上跳图标 → 返回。
  - 拖拽节点/线段调整时间：**粒度=月**（吸附月边界），区间任务拖中段平移、拖端点改起止。
  - **不允许时间跨度 ≥ 一整年**的任务（拖拽吸附时钳制）；年度任务用 `is_annual` 表达。
  - 点击节点/线段/名称 → 任务编辑器（§7）。

### 2.2 月视图

- 布局：4–6 行（每周一行，覆盖当月），每行 7 列（**星期日 → 星期六**）。
- 结构是年视图的"日级同构"：每个日格内沿用节点/线段 + 泳道（高度受限时只画节点，名称层省略）；跨日任务画跨格线段；**今天高亮**。
- 点击日格 → 下钻日视图；拖拽粒度=日；其余同年视图。

### 2.3 日视图

- 横轴 00:00–24:00：每 30 分钟一个刻度点，每小时一条竖格线；**比例尺可捏合缩放**（最宽到每 5 分钟一个节点的密度）。
- 任务表示：时间点任务=节点；时间段任务=**带断点的线段**（端点为断点方块）；**当前时间 = 一条高亮竖线**（定时器每分钟重绘）。
- 名称层（甘特图上方独立区域，45° 斜向上文本带）：
  - 仅当比例尺达到"每 5 分钟一个节点且每个名称文本都放得下"时才显示名称；
  - 时间点任务：从节点向上引**虚线**指向其斜文本名称；
  - 时间段任务：在其时间范围内**尽量找靠前的名称空位**，垂直向上连一条虚线到线段；
  - 名称空位分配是纯函数 `assignDayNames(tasks, scale)`：按开始时间升序，斜文本带从下往上、从左往右试放，与已放置的文本框（旋转 45° 的 OBB）做碰撞检测，找到即放；**找不到空位的任务不显示名称**（节点/线段仍在）。
- 交互：拖拽节点/线段调整时间，**粒度=5 分钟**（吸附）；点击 → 任务编辑器；上跳图标回月视图。

### 2.4 视图间导航

```
年视图 --点月块--> 月视图 --点日格--> 日视图
   <--上跳按钮--        <--上跳按钮--
```

每个视图顶部：粒度切换图标组（年/月/日，等宽分段控件，见 §9）+ 今天按钮 + 上跳按钮（在最细粒度时可回跳）。

## 3. 模块二：待办

单页分组列表，分组即全部视图（不做二级页）：

| 分组 | 内容 | 排序 |
|---|---|---|
| 我的待办 | start_at 为空 且 status=active | 优先级→创建时间 |
| 今天 | 时间范围与今天有交集 且 active | 开始时间 |
| 本周 / 本月 / 本季度 / 本年 | 同理（与自然周期交集） | 开始时间 |
| 年度任务 | is_annual=1 | **逐年分节列出，即使该年没有任务也显示年份标题**（从今年起 5 年） |
| 已完成 | status=done（24h 内置顶，其余沉底） | 完成时间倒序 |
| 已归档 | status=archived | 归档时间倒序 |

- 行内：勾选框（完成/取消完成）、三色优先级点、时间摘要、来源消息角标（点按跳转消息）。
- 点按行 → 任务编辑器（§7）；新增按钮 → 空白任务编辑器。
- 完成 → 撤销 SnackBar；归档 → 撤销 SnackBar（撤销见 §6）。

## 4. 模块三：笔记

- 三级导航：笔记本列表 → 章节列表 → 笔记编辑器（纯文本，`content_format=plain`，Markdown 预留）。
- 每层可增删改排序；删除笔记本/章节为级联删除（进撤销队列的复合操作）。
- 编辑器：标题 + 正文，退出自动保存；暂不做同步、不做版本历史。

## 5. 模块四：消息（数据源）

### 5.1 消息列表

- 排序：**未处理(none/pending) → 红 → 黄 → 绿 → 垃圾**，组内按 posted_at 倒序；每组有吸顶分组头（可折叠）。
- 行标记（左端）：
  - 有空心圆点 = 未处理；
  - 颜色圆点 = 已评估（红/黄/绿）；
  - 有任务关联 = 圆点右侧叠加小角标；
  - 垃圾 = 整行**灰色消息块**（降饱和、划线标题）。
- 左滑 → **块状菜单**（圆角色块按钮，非列表）：

| 状态 | 菜单项 |
|---|---|
| 未处理 | 自动处理（AI 评估+可选生成任务） / 创建任务 / 标记垃圾 / 归档 |
| 已处理 | 重新处理（AI 再评） / 创建任务或删除任务（视有无 linked_task）/ 标记垃圾 / 归档 |
| 垃圾 | 移出垃圾 / 归档 |
| 已归档（归档页） | 取出 / 删除 |

- 筛选器行：状态分组多选 + 应用筛选（统一 Chip 行，见 §9）；多选模式：
  - 长按进入多选；底部出现**图标按钮条**；菜单项可用性 = 所选消息**能力交集**（如混选"垃圾+非垃圾"时"标记垃圾/移出垃圾"均禁用，"归档"可用）。
- 已归档消息独立页签，左滑=取出/删除，多选同上。
- 「导入」入口（微信/QQ/短信）：占位按钮 + "即将支持"提示，协议字段（capture_type=import, import_source）已预留。

### 5.2 消息与任务联动

- 创建任务：以消息标题为默认任务名、正文为描述进入编辑器，保存后 `messages.linked_task_id` 与 `tasks.source_message_id` 互链。
- 删除任务（从消息菜单）：删除 linked_task（进撤销队列）。
- AI 自动处理：产出 priority + 可选任务草稿；草稿需用户在结果面板一键确认才落 tasks（不静默建任务）。

## 6. 撤销系统

- **UndoService（内存单例）**：队列元素 = { id, label, execute() 的逆操作闭包, enqueuedAt }。
- 规则：
  1. 任何数据变更操作**执行成功后**将其逆操作入队，TTL=10 秒，过期丢弃；
  2. 撤销 = 弹出**最晚入队**的有效项并执行其逆操作（后来者先撤）；
  3. 被撤销的操作从队列**永久移除**（不做重做）；
  4. 新操作入队时若队列中已有更晚的分支点（即发生过撤销后的新操作），丢弃另一分支——实现为：撤销只弹栈、入队即截断，天然满足"分叉丢弃另一分支"；
  5. 批量操作（多选）作为一个**复合逆操作**入队，撤销时整体回滚。
- UI：每次操作后 SnackBar 显示"已 XX · 撤销(10s)"；连续操作队列式替换 SnackBar。

## 7. 任务编辑器（全功能手动编辑）

对话框/半屏页，字段：

| 字段 | 约束 |
|---|---|
| 名称 | 必填；**宽度上限 36**：全角字符与中文计 2、ASCII 计 1、emoji 按 grapheme cluster 计 2（`characters` 包），实时宽度条提示，超限禁保存 |
| 描述 | 可选，多行纯文本 |
| 类型 | 时间点 / 时间段（切换时保留已有时间） |
| 时间 | 开始（日期+时间，可清空=无时间任务）；时间段时加结束；年视图拖入的月级任务默认 1 日 09:00 |
| 优先级 | 重要 / 一般 / 不重要（对应红/黄/绿） |
| 年度任务 | 开关（开启则禁选跨年跨度） |
| 来源 | 只读展示来源消息（若有），可跳转 |

- 任务可以没有原消息——编辑器独立入口（待办页 + 按钮、日程页长按空白、消息菜单"创建任务"）。
- 删除任务在编辑器底部（进撤销队列）。

## 8. AI 处理

### 8.1 路由（AiClient）

```
process(messages):
  if 电脑端 health 探测在线（30s 缓存） → POST /v1/process（adb 通道，自动配对 token）
  else → 设置中的默认远程 API（OpenAI 兼容 /chat/completions, SSE）
```

- 远程接口配置：多套 { name, baseUrl, apiKey, model }，设置页管理，选默认；电脑端条目自动生成只读（标注"已连接/未连接"）。

### 8.2 处理目标

对一批消息，AI 输出（每消息一条）：

```json
{
  "priority": "red|yellow|green|junk",
  "reason": "一句话理由",
  "taskDraft": { "title": "...", "description": "...", "kind": "point|range",
                 "startAt": "YYYY-MM-DDTHH:mm", "endAt": "...", "priority": "important|normal|minor" } | null
}
```

- 筛选重要 vs 垃圾是 AI 的**第一职责**（垃圾：营销、推广、无用系统提示等）；任务草稿是第二职责（仅当消息包含明确可执行事项）。
- 提示词仍由注册表/分类描述生成（沿用 v1 资产），但输出 schema 换成上面的精简结构；时间解析沿用"日期对照表 + 已过去顺延 + 本地时间字符串"策略。

### 8.3 流式展示（v1）

- 电脑端 NDJSON 增加事件 `{"type":"token","messageId":"...","delta":"..."}`（provider 以 stream 模式调模型，边生成边透传）。
- 手机直连远程 API 时直接读 SSE delta。
- UI：处理中底部升起"AI 处理中"面板——当前消息标题 + **实时滚动的原始输出文本** + 已完成计数；完成后面板汇总"评估 x 条 / 垃圾 y 条 / 任务草稿 z 条"，用户逐条或批量确认。
- 可视化展示（时间线动画等）留后续版本。

## 9. 设置

- **外观**：主题（跟随系统/浅色/深色）——分段控件**等宽三格**，不再换行（修复 v1 缺陷）。
- **自定义提示词**：多行文本，随每次处理请求下发。
- **AI 接口**：接口列表（电脑端自动条目 + 多套远程 API）、默认选择、连通测试。
- **连接**：通道状态、配对信息（自动配对的 token 可重置）、采集过滤（沿用应用过滤器，样式并入统一 Chip 规范）。

## 10. UI 规范（v2 全局，顺带修复 v1 三处缺陷）

1. **分段控件一律等宽**：固定总宽内均分，选中态只改底色不改宽度（修复：结构化页顶部按钮组切换时宽度抖动、外观"跟随系统"选中换行）。
2. **筛选器统一 Chip 行**：状态 Chip + 应用 Chip 同行等样式、可横向滚动，不再突兀浮出（修复：收件箱应用筛选器样式）。
3. 深色模式沿用 v1（Material 3 ColorScheme，seed 不变）；所有自绘视图颜色从 ColorScheme 派生。
4. 底部 5 tab：日程 / 待办 / 笔记 / 消息 / 设置，图标+文字居中。

## 11. 电脑端（Electron 状态栏应用）

- 打包：Electron（主进程 only，无前端框架），macOS 菜单栏 Tray（Windows 托盘预留）。
- 菜单项：服务状态（运行中/已停止）、手机连接（已连接设备名/未连接，adb 检测循环）、模型管理（当前模型、启停本地推理进程、切换配置）、配对（查看/重置 token）、开机自启、关于、退出。
- 主进程职责 = 现有 server.ts（HTTP :8765）+ connect.ts（adb 看护）+ 模型进程管理；业务数据只留 items.jsonl 作为处理日志，**dashboard 删除**。
- 自动配对：`POST /v1/pair`（免认证，仅 loopback 可达）→ 返回当前 token 或重新签发；手机端 401 时自动调用一次完成配对。
- 分发：`npm run dist`（electron-builder，macOS dmg）；开发期 `npm run electron`。

## 12. 协议变更摘要（相对 v1）

| 项 | v1 | v2 |
|---|---|---|
| 同步方向 | 手机上送消息，电脑回结构化结果 | 手机是 AI 调用方；电脑只提供 `/v1/process`（流式评估） |
| 结构化实体 | StructuredItem（电脑端产出并存储） | tasks/notes 全在手机端；AI 只产出 priority + taskDraft |
| 认证 | 手动输入 token | 自动配对（/v1/pair），旧 token 兼容 |
| 流式 | NDJSON（progress/done） | NDJSON + token 事件（原始输出透传） |
| dashboard | 有 | 删除（状态栏状态窗口取代） |

`/v1/sync` 保留一个版本周期供旧手机端使用，标记 deprecated。

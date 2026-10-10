# 总体架构

## 系统定位

MsgRepo 是一个"通知消化"系统：手机端无差别收集通知，电脑端本地 AI 负责理解，把杂乱的原始通知提炼为结构化的日程、待办、笔记等，手机端负责呈现与提醒。**原始消息只经有线 ADB 通道传输，AI 推理完全在本地，数据不出本机。**

## 职责划分

```
┌─────────────────────┐   adb forward    ┌─────────────────────┐
│   手机端 (Flutter)   │  tcp:8765 ════  │  电脑端 (TS/Node)    │
│                     │ ◀══ HTTP/JSON ══ │                     │
│ · 通知监听采集        │   （USB 有线）   │ · HTTP 服务          │
│ · 手动添加+附件引用    │                 │ · AI 适配层          │
│ · 注册表权威持有者     │                 │ · 处理管线           │
│ · 状态标记/展示       │                 │ · 结果存储           │
│ · 本地提醒调度        │                 │ · Web 仪表盘         │
└─────────────────────┘                 │ · 本地 AI 模型        │
                                        │  (Ollama/OpenAI兼容) │
                                        └─────────────────────┘
```

分工原则：**手机端拥有数据和用户，电脑端拥有算力。**

| 职责 | 手机端 | 电脑端 |
|---|---|---|
| 通知采集、手动录入 | ✔ | |
| 分类注册表的权威来源 | ✔ | （使用方） |
| 去重、分类、抽取、时间解析 | | ✔ |
| payload 校验与降级 | | ✔ |
| 消息状态标记、结果展示 | ✔ | ✔（仪表盘为附加显示） |
| 提醒调度 | ✔ | |

## 连接拓扑

电脑端在 `127.0.0.1:8765` 起 HTTP 服务。USB 连接后执行：

```bash
adb forward tcp:8765 tcp:8765
```

此后手机上的 `http://127.0.0.1:8765` 即电脑的 8765 端口。通道是 USB 本地的，不经过任何网络，天然满足"安全稳定优先"。

传输层在手机端抽象为 `SyncClient`（host/port 可配）、电脑端只监听 loopback。后续扩展无线 ADB（`adb connect <ip>` 后同样 `adb forward`）或局域网直连时，业务代码不变，只改连接建立方式——见 `docs/extensibility.md`。

## 信任与认证

- 首次使用电脑端生成配对 token（打印在控制台，写入 `desktop/data/pairing.json`），用户在手机端"我的"页输入；
- 之后手机端每个请求携带 `Authorization: Bearer <token>`；
- 电脑端只绑定 `127.0.0.1`，不经 ADB forward 无法到达，token 是第二道防线。

## 数据流向

```
采集：Android 系统 ─▶ NotificationCaptureService(Kotlin)
        ─▶ 队列文件(原子写) ─▶ Dart 轮询 ─▶ sqflite(raw_messages, pending)

同步：sqflite pending ─▶ SyncClient ─▶ POST /v1/sync
        ─▶ 电脑端管线 ─▶ StructuredItem[]
        ─▶ 手机：raw_messages 置 processed、structured_items 入库、调度提醒

手动：add_message_page ─▶ sqflite(captureType=manual, attachments=访问方式)
        ─▶ 与通知走同一条同步管线
```

## 仓库结构

```
MsgRepo/
├── shared/
│   ├── schemas/     # 5 份 JSON Schema，两端契约的唯一事实源
│   └── registry/    # 默认分类注册表 default.json（打包进手机 assets，电脑端内置副本）
├── desktop/         # TypeScript/Node：HTTP 服务 + AI 管线 + 仪表盘
├── mobile/          # Flutter(Android)：采集 + 同步 + 展示 + 提醒
└── docs/            # 本文档及数据模型、协议、AI 管线、扩展指南
```

## 关键取舍

- **为什么手机端是注册表权威**：分类体系体现用户的整理习惯，用户在手机上感知分类结果并决定增删分类；电脑端是无状态处理器，重启/换机不丢用户配置。
- **为什么 AI 不在手机上跑**：端侧模型能力与电量受限；电脑端可用 Ollama 跑更大的本地模型，且适配层支持任何 OpenAI 兼容服务。
- **为什么不用云端同步**：设计目标就是数据不出本机；ADB 有线通道是这一约束下最简单可靠的方案。

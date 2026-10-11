# 同步协议

手机（客户端）与电脑（服务端）之间的全部通信。机器可校验的定义见 `shared/schemas/sync-request.schema.json` 与 `sync-response.schema.json`。

## 传输层

- 电脑端 HTTP 服务绑定 `127.0.0.1:8765`（端口可在 `desktop/config/default.json` 配置）
- 手机通过 `adb reverse tcp:8765 tcp:8765` 访问 `http://127.0.0.1:8765`
- 请求体/响应体均为 JSON，`Content-Type: application/json; charset=utf-8`

## 认证

```
Authorization: Bearer <pairing-token>
```

- token 由电脑端首次启动时生成（≥32 字节随机值的 hex），打印到控制台并写入 `desktop/data/pairing.json`（权限 0600）
- 手机端在设置页输入后存于 `shared_preferences`
- `GET /v1/health` 免认证（用于手机端"连接测试"在输入 token 前验证通道）；其余端点认证失败返回 `401`

## 端点

### `GET /v1/health`

连通性检查。响应：

```json
{ "ok": true, "server": "msgrepo-desktop", "version": "0.1.0", "registryVersion": "1.0.0" }
```

手机端可据此判断：通道是否通、两端注册表版本是否一致。

### `POST /v1/sync`

核心端点。请求体（sync-request.schema.json）：

```json
{
  "deviceId": "pixel-7-abc123",
  "registryVersion": "1.1.1",
  "registry": { "...完整注册表，可选..." },
  "customPrompt": "把直播开播提醒都当作营销处理",
  "reprocessMessageIds": ["uuid-9"],
  "stream": true,
  "messages": [ { "...RawMessage..." } ]
}
```

规则：

1. `messages` 只含 `status=pending` 的消息，按 `postedAt` 升序；单次建议不超过 200 条，超出由手机端分批
2. `registry` 仅当手机端发现两端版本不一致（health 或上一次 sync 响应得知）时携带；电脑端收到后**采用手机端的注册表**并持久化（手机是权威来源）
3. `customPrompt`（可选）：用户在手机端维护的自定义提示词，电脑端追加到 AI 系统提示词末尾，用于调整分类/优先级表现而不改注册表
4. `reprocessMessageIds`（可选）：用户回退（processed→pending）的消息 id，电脑端对这些消息**跳过去重**强制重新处理；手机端同步成功后清除本地的 needs_reprocess 标记
5. `stream`（可选）：为 `true` 时电脑端以 **NDJSON 流式响应**（`Content-Type: application/x-ndjson`），逐条下发处理进度；缺省为一次性 JSON 响应
6. 空 `messages` 合法——退化为"注册表协商 + 心跳"

**流式响应**（`stream: true`）：每行一个 JSON 事件——

```jsonl
{"type":"warning","message":"注册表版本不一致…"}
{"type":"progress","item":{"...StructuredItem..."},"processedMessageIds":["uuid-1"],"warnings":["..."]}
{"type":"progress","processedMessageIds":["uuid-2"]}
{"type":"done","registryVersion":"1.1.1","failedMessageIds":["uuid-3"],"warnings":["..."]}
```

- 每条消息处理完电脑端**立即落盘并发出一个 progress 事件**；`item` 为该消息产出（或去重找回、归并后更新）的条目，重复消息可能不带 `item`
- 手机端每收到一个事件就入库/置状态/调度提醒并刷新 UI；连接中断时已完成的部分不丢，剩余消息保持 `pending` 等下次同步
- 手机端对流应用**空闲超时**（240s 无新事件视为断流），而非整体超时——大批量处理总时长不受限

普通响应体（sync-response.schema.json）：

```json
{
  "registryVersion": "1.0.0",
  "results": [ { "...StructuredItem..." } ],
  "processedMessageIds": ["uuid-1", "uuid-2"],
  "failedMessageIds": ["uuid-3"],
  "warnings": ["2 条结果 payload 校验失败，已降级为 generic"]
}
```

手机端收到 200 后的动作：

1. `processedMessageIds` → 本地 `raw_messages.status = processed`
2. `failedMessageIds` → 保持 `pending`，下轮重试；连续失败 ≥3 次标记 `archived` 并在 UI 提示
3. `results` → 写入 `structured_items`，对 `time.kind ≠ none` 且 `reminderOffsets` 非空的条目调度本地提醒
4. 响应中的 `registryVersion` 与本地不一致 → 下次请求携带完整 `registry`

错误响应：

| 状态码 | 含义 | 手机端行为 |
|---|---|---|
| 400 | 请求体不符合 schema | 记录日志，提示用户升级 App |
| 401 | token 错误/缺失 | 跳转设置页重新配对 |
| 413 | 请求过大 | 减半批量重试 |
| 500 | 电脑端内部错误 | 保持 pending，稍后重试 |

### `GET /api/items`（仪表盘用）

电脑端本地查询已处理的 StructuredItem，支持 `?category=`、`?priority=` 过滤。仅供仪表盘，手机端不使用。

## 配对流程（首次使用）

```
1. 电脑端 npm run connect → 自动拉起服务并建立 adb reverse，控制台打印 token（或 npm run pair 查看）
2. 手机 USB 连接（connect 会等待 USB 调试授权；手动方式则是 npm start + adb reverse tcp:8765 tcp:8765）
3. 手机端设置页输入 token → 点"连接测试"（GET /v1/health + 一次空 sync 验证 token）
4. 配对完成，之后每次同步自动携带
```

连接看护：`npm run connect` 启动后每 5 秒检查一次——服务未运行则拉起（已在运行则复用）、adb reverse 通道丢失则重建，适合长时间挂机使用。

## 幂等与重试

- 手机端重发同一条消息是安全的：电脑端按 `contentHash` + 内容键（`sha256(packageName|title|body)`，不含 postedAt）双重去重——应用重投/折叠更新产生的"只有时间不同"的重复内容也能命中；已处理过的消息直接归入 `processedMessageIds` 并**找回既有结构化结果**一并返回
- 电脑端逐条处理、逐条落盘（append-only 的 `items.jsonl`）；流式模式下每处理完一条立即下发，中途断线时两端已完成的进度都不丢，未处理的消息保持 `pending` 下次继续
- 重复处理同一哈希不会产生重复结果（找回机制复用原条目）

## 版本兼容

- 协议路径带主版本号 `/v1/`；破坏性变更走 `/v2/`，新旧端点并存一个过渡期
- `StructuredItem.schemaVersion` 与 `CategoryRegistry.version` 各自独立演进，规则见 `docs/data-model.md` 第 5 节

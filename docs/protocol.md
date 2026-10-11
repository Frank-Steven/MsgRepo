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
  "registryVersion": "1.0.0",
  "registry": { "...完整注册表，可选..." },
  "messages": [ { "...RawMessage..." } ]
}
```

规则：

1. `messages` 只含 `status=pending` 的消息，按 `postedAt` 升序；单次建议不超过 200 条，超出由手机端分批
2. `registry` 仅当手机端发现两端版本不一致（health 或上一次 sync 响应得知）时携带；电脑端收到后**采用手机端的注册表**并持久化（手机是权威来源）
3. 空 `messages` 合法——退化为"注册表协商 + 心跳"

响应体（sync-response.schema.json）：

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
1. 电脑端 npm start → 控制台打印 token（或 npm run pair 查看）
2. 手机 USB 连接，adb reverse tcp:8765 tcp:8765
3. 手机端设置页输入 token → 点"连接测试"（GET /v1/health + 一次空 sync 验证 token）
4. 配对完成，之后每次同步自动携带
```

## 幂等与重试

- 手机端重发同一条消息是安全的：电脑端按 `contentHash` 去重，已处理过的哈希直接归入 `processedMessageIds` 返回
- 手机端只有在收到 200 后才把消息置 `processed`；中途断线消息保持 `pending`，下次重发
- 电脑端结果持久化为 append-only 的 `items.jsonl`，重复处理同一哈希不会产生重复结果

## 版本兼容

- 协议路径带主版本号 `/v1/`；破坏性变更走 `/v2/`，新旧端点并存一个过渡期
- `StructuredItem.schemaVersion` 与 `CategoryRegistry.version` 各自独立演进，规则见 `docs/data-model.md` 第 5 节

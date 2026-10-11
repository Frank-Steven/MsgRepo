# 扩展指南

本系统的设计原则是"分类体系是数据，不是代码"。多数扩展不需要改动核心逻辑。

## 1. 新增一个分类（最常见）

编辑注册表（手机端打包的 `shared/registry/default.json`，发布后由手机端持有并可在线更新），追加一个对象：

```json
{
  "key": "shopping_order",
  "displayName": "购物订单",
  "description": "电商订单状态：『您的订单已发货，运单号 SF1234』『确认收货后评价得积分』。",
  "baseKind": "generic",
  "defaultPriority": "P3",
  "priorityHints": "发货/派送 P2；确认收货提醒 P3",
  "timeHints": "通常无时间，自动确认收货截止可用 deadline",
  "payloadSchema": {
    "type": "object",
    "required": ["fields"],
    "properties": { "fields": { "type": "array", "items": { "$ref": "#/definitions/genericField" } } }
  }
}
```

然后升 `version`（如 `1.0.0` → `1.1.0`）。效果：

- 下次同步时手机把新注册表发给电脑，AI 提示词自动包含新分类；
- 两端 UI 无需改动（generic 分类按 fields 逐行渲染）；
- 完成，零代码改动。

**何时提升为 specialized**：当某分类高频出现且值得专门 UI（如待办的勾选交互）时，把 `baseKind` 改为 `specialized`、写正式 payloadSchema，并在手机端加对应渲染组件。信封协议不变。

写好 `description` 的关键：多给典型措辞样例，AI 主要靠它区分相近分类（"账单" vs "优惠"）。

## 2. 接入新的 AI 服务

实现 `desktop/src/ai/provider.ts` 的 `AIProvider` 接口（一个 `process` 方法），在 `config/default.json` 把 `provider` 指过去即可。已有的 `ollama.ts` / `openai-compat.ts` 可作为模板。

常见服务直接用 `openai-compatible` 即可：llama.cpp server、LM Studio、vLLM、Text Generation WebUI 都暴露 OpenAI 兼容端点，只需改 `baseUrl` 和 `model`。

选择模型的建议：

- 需要可靠的 JSON 结构化输出能力（这是硬指标，比聊天能力重要）
- 中文理解好（通知基本是中文）
- 8B 量化模型是本地体验的下限，14B+ 更稳

## 3. 扩展无线连接

当前：有线 ADB（`adb reverse`）。扩展路径：

1. **无线 ADB**：手机和电脑同局域网，`adb connect <手机ip>:5555` 后同样执行 `adb reverse`——协议层零改动，手机端无感知；
2. **局域网直连**：电脑端监听改为 `0.0.0.0`，手机端 `SyncClient` 的 host 改为电脑局域网 IP。**必须同时加强安全**：token 认证已有，建议再加 TLS（自签证书 + 手机端固定证书指纹）。这是放宽了"数据不出 USB 线"的安全模型，默认不启用。

手机端传输配置集中在 `SyncClient`（host/port/token 可配），业务代码不感知传输方式。

## 4. 新增附件类型

1. `raw-message.schema.json` 的 `kind` 和 `access.type` 枚举加值；
2. 手机端 `add_message_page.dart` 加对应采集方式；
3. 若 AI 需要理解附件内容（如 OCR 图片），新增"按需拉取附件"端点（附件已有 `id`），这属于协议 `/v2` 范围。

## 5. 快速通道（未来优化）

验证码等 P0 消息目前要等同步才有价值。可在手机端加本地正则快速提取（验证码模式极其规整），直接本地生成 StructuredItem 并立即提醒，同步时由电脑端复核。这是"手机端拥有数据"原则的自然延伸，协议无需变更。

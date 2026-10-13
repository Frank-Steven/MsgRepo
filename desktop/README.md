# MsgRepo Desktop（电脑端）

手机（Flutter）采集 Android 通知，经 `adb reverse` 访问电脑端 HTTP 服务；电脑端用本地 AI（Ollama / OpenAI 兼容 API / 内置 mock 规则引擎）把原始消息结构化为日程/待办/笔记等 StructuredItem 返回手机，并附带一个 Web 仪表盘。

## 安装

```bash
cd desktop
npm install
```

要求 Node 18+（开发用 tsx，构建产物在 dist/，`npm run build` 生成）。

## 快速开始

```bash
npm run demo    # 不启服务，用 MockProvider 跑 6 条示例消息，端到端演示管线
npm run pair    # 查看/生成配对 token
npm start       # 启动 HTTP 服务（默认 127.0.0.1:8765）
npm run connect # 一键连接：拉起/复用服务 + adb reverse + 5 秒看护自动重连（推荐日常使用）
```

`npm run connect` 会检测服务是否已在运行（在则复用，不再起第二个）、等待手机 USB 调试授权、建立 `adb reverse`，随后每 5 秒看护：通道掉了自动重建、服务进程退出自动拉起。控制台持续打印配对 token 与仪表盘地址。

## macOS 状态栏应用（Electron）

```bash
npm run electron  # 开发模式：先 tsc 再启动 Electron（状态栏图标，无 Dock 图标/主窗口）
npm run dist      # electron-builder 打包，产出 release/MsgRepo-<version>-arm64.dmg
npm run icons     # 重新生成 assets/ 下的托盘/应用图标（程序化绘制，无美术资源）
```

托盘菜单：服务状态（地址/AI provider 与模型）、手机连接状态（adb 检测，每 5 秒看护自动重建 reverse 通道，无设备时静默重试）、配对码（复制/重置）、打开仪表盘、开机自启开关、退出。

实现说明：

- 主进程 `src/electron-main.ts`（编译为 `dist/electron-main.js`，package.json `main` 指向它；Electron 28+ 的 ESM 主进程）。
- HTTP 服务进程内启动（复用 `server.ts`）；若 8765 已被 CLI 等服务占用则直接复用，不重复拉起。
- adb 逻辑抽在 `src/adb.ts`，CLI（connect.ts）与托盘共用。
- 托盘应用的数据目录是 `~/Library/Application Support/MsgRepo`（`app.getPath("userData")`），与 CLI 的 `desktop/data/` 相互独立。
- 打包配置在 package.json 的 `build` 字段：`shared/` 经 extraResources 拷入包内（`registry.ts` 有回退路径），不签名（`identity: null`）、asar 关闭、`LSUIElement` 隐藏 Dock 图标。

首次启动会自动生成配对 token 打印到控制台并写入 `data/pairing.json`。之后可用 `npm run pair` 再查看。

手机端连接（手动分步方式）：

```bash
adb reverse tcp:8765 tcp:8765
# 手机端请求 http://127.0.0.1:8765，带请求头：
# Authorization: Bearer <token>
```

## HTTP 接口

| 方法 | 路径 | 认证 | 说明 |
| --- | --- | --- | --- |
| GET | `/v1/health` | 免 | 健康检查 |
| POST | `/v1/sync` | Bearer | 请求/响应体遵循 `shared/schemas/sync-request.schema.json` / `sync-response.schema.json`；支持可选 `customPrompt`（追加到 AI 系统提示词末尾）与 `reprocessMessageIds`（跳过 contentHash 去重强制重处理） |
| GET | `/dashboard` | 免 | Web 仪表盘（页面内输入 token 后拉取数据） |
| GET | `/api/items?category=&priority=` | Bearer | 查询已处理的 StructuredItem |

## 配置 AI provider

配置在 `config/default.json`；本地覆盖用 `config/local.json`（已被 git 忽略）。

- **mock**（默认）：内置规则引擎，关键词分类 + 正则抽取（验证码/取件码/金额/中文相对时间），无需任何模型即可端到端跑通。
- **ollama**：`"provider": "ollama"`，配置 `ollama.baseUrl`（默认 `http://127.0.0.1:11434`）与 `ollama.model`。调 `/api/chat`，payload 抽取步骤把该分类的 `payloadSchema` 作为 `format` 约束 JSON 输出。
- **openai-compatible**：`"provider": "openai-compatible"`，配置 `openai.baseUrl` / `openai.model`，API key 从 `openai.apiKeyEnv` 指定的环境变量读取（默认 `OPENAI_API_KEY`）。使用 `response_format=json_object`（端点不支持时 400 自动降级为纯 prompt 约束）。首次分类落到 generic 时会自动发起第二次更强势的分类请求，逼模型在具体分类中选最贴近的；二次仍 generic 则接受并把 confidence 压到 ≤0.4，让手机端标记"待确认"。

## 处理管线

`src/pipeline.ts`：contentHash 去重 → provider 分类+抽取 → 相对时间以 `postedAt` 为基准解析为绝对毫秒 → 优先级缺省回退注册表 `defaultPriority` → ajv 按注册表 `payloadSchema` 校验 payload（失败降级为 generic，原 payload 平铺进 `fields`，并记录 warning）→ 同分类且标题高度相似的消息归并 `rawMessageIds`。结果追加持久化到 `data/items.jsonl`。

## 目录

```
config/default.json   默认配置（config/local.json 可覆盖）
data/                 CLI 运行期数据（pairing.json / items.jsonl / hashes.json / registry.json，git 忽略）
assets/               托盘/应用图标（npm run icons 生成）
scripts/make-icons.mjs 图标生成脚本
src/                  index.ts(CLI) connect.ts(一键连接看护) electron-main.ts(托盘主进程) adb.ts config.ts server.ts auth.ts registry.ts pipeline.ts store.ts types.ts ai/
```

## 已知限制

- mock 的时间解析只覆盖常见中文表达（今天/明天/后天/HH:mm/x小时后/x分钟内/x月x日）。
- Ollama 的 `format` 对含 `$ref` 的 payloadSchema 支持取决于模型/版本，若输出不合规，管线会自动降级为 generic。
- 结果存储为 JSONL 追加文件，无索引，量大后 `/api/items` 会变慢。

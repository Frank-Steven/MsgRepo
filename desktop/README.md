# MsgRepo Desktop（电脑端）

手机（Flutter）采集 Android 通知，经 `adb reverse` 访问电脑端 HTTP 服务；电脑端用本地 AI（默认 llama.cpp `127.0.0.1:8080`，OpenAI 兼容协议）把原始消息评估为优先级 + 任务草稿返回手机。电脑端只是「AI 接口 + 服务管理器」，全部功能在手机端。

## 日常使用：macOS 状态栏应用（无需终端）

安装：

1. `npm run dist` 产出 `release/MsgRepo-0.2.0-arm64.dmg`（或拿到 dmg 文件）。
2. 打开 dmg，把 **MsgRepo.app** 拖入「应用程序」。
3. 首次启动：应用未签名，需要在「应用程序」里**右键 → 打开**，在弹窗中确认。之后双击/开机自启均可直接运行。

启动后没有任何窗口和 Dock 图标，只在状态栏出现一个气泡图标。启动即自动完成：内嵌 HTTP 服务（`127.0.0.1:8765`）→ 探测 adb → 手机接入自动识别 → 自动 `adb reverse` → 5 秒看护（断线重连、服务掉线重拉）。

托盘菜单：

| 菜单项 | 说明 |
| --- | --- |
| 服务 | 运行中地址 / 复用已有进程 / 启动失败原因（如端口被占用） |
| AI 后端 | 本地模型连通性（`127.0.0.1:8080` + 模型名）；不可达时手机端自动改走远程 API |
| 手机 | 已连接设备（型号 + 序列号 + 通道状态）/ 待授权 / 未连接 / 未检测到 adb |
| 最近事件 | 最近 5 条状态事件（时间戳） |
| 配对码 | 复制 / 重置（手机端 401 时会自动重新配对，一般无需手动操作） |
| 打开仪表盘 | 浏览器打开 `http://127.0.0.1:8765/dashboard` |
| 开机自启 | macOS login item 开关 |
| 退出 | 停止内嵌服务并退出 |

状态变化通过系统通知提示：手机已连接/断开、待 USB 授权、AI 后端不可达/恢复、服务启动失败、未检测到 adb。（应用未签名，macOS 可能不弹通知——所有状态以托盘菜单为准。）

### 前置要求：adb

手机经 USB 连接需要 adb（Android Platform Tools）。托盘找不到 adb 时菜单里会出现「复制安装命令」和下载页入口：

```bash
brew install android-platform-tools
```

托盘会依次探测：PATH → `$ANDROID_HOME/platform-tools/adb` → `/opt/homebrew/bin/adb` → `/usr/local/bin/adb` → `~/Library/Android/sdk/platform-tools/adb`。装好 adb 后 5 秒内自动识别，无需重启应用（首次需手机授权 USB 调试）。

### 配置覆盖（AI 后端等）

托盘应用配置生效顺序：包内 `config/default.json` → `~/Library/Application Support/MsgRepo/config.json`（存在则浅合并覆盖）。默认配置即本地 llama.cpp（`provider=openai-compatible`，`baseUrl=http://127.0.0.1:8080/v1`）；要改后端/端口，编辑 userData 下的 `config.json` 后重启应用即可。

数据目录 `~/Library/Application Support/MsgRepo/`（pairing.json / items.jsonl 等），与 CLI 的 `desktop/data/` 相互独立。

## 开发（CLI）

```bash
cd desktop
npm install        # 要求 Node 18+
npm run demo       # 不启服务，用 MockProvider 跑 6 条示例消息，端到端演示管线
npm run pair       # 查看/生成配对 token
npm start          # 启动 HTTP 服务（默认 127.0.0.1:8765）
npm run connect    # 开发调试用：拉起/复用服务 + adb reverse + 5 秒看护（日常使用请用托盘应用）
npm run electron   # 开发模式跑托盘应用（tsc + electron .）
npm run dist       # electron-builder 打包 dmg 到 release/
npm run icons      # 重新生成 assets/ 下的托盘/应用图标（程序化绘制，无美术资源）
```

实现说明：

- 主进程 `src/electron-main.ts`（编译为 `dist/electron-main.js`，package.json `main` 指向它；Electron 28+ 的 ESM 主进程）。
- HTTP 服务进程内启动（复用 `server.ts`）；若 8765 已被其他 MsgRepo 进程占用则直接复用，不重复拉起。
- adb 逻辑在 `src/adb.ts`，CLI（connect.ts）与托盘共用。
- 打包配置在 package.json 的 `build` 字段：`shared/` 经 extraResources 拷入包内（`registry.ts` 有回退路径），不签名（`identity: null`）、asar 关闭、`LSUIElement` 隐藏 Dock 图标。
- 开发环境 Electron 二进制若因 npm install-scripts 拦截未下载，需手动执行 `node node_modules/electron/install.js`。

## HTTP 接口

| 方法 | 路径 | 认证 | 说明 |
| --- | --- | --- | --- |
| GET | `/v1/health` | 免 | 健康检查 |
| POST | `/v1/pair` | 免 | 自动配对：返回当前 token；`{"reset":true}` 重新签发（仅 loopback 可达） |
| POST | `/v1/process` | Bearer | v2 流式评估（NDJSON：token/result/done 事件） |
| POST | `/v1/sync` | Bearer | Deprecated：v1 同步协议，保留一个版本周期 |
| GET | `/dashboard` | 免 | Web 仪表盘（页面内输入 token 后拉取数据） |
| GET | `/api/items?category=&priority=` | Bearer | 查询已处理的 StructuredItem |

## 配置 AI provider

配置在 `config/default.json`；CLI 本地覆盖用 `config/local.json`（git 忽略），托盘应用覆盖用 userData 的 `config.json`。

- **openai-compatible**（默认）：指向本地 llama.cpp（`http://127.0.0.1:8080/v1`）或任何 OpenAI 兼容端点，配置 `openai.baseUrl` / `openai.model`，API key 从 `openai.apiKeyEnv` 指定的环境变量读取（本地 llama.cpp 无需 key）。使用 `response_format=json_object`（端点不支持时 400 自动降级为纯 prompt 约束）。首次分类落到 generic 时会自动发起第二次更强势的分类请求；二次仍 generic 则接受并把 confidence 压到 ≤0.4。
- **mock**：内置规则引擎，关键词分类 + 正则抽取（验证码/取件码/金额/中文相对时间），无需任何模型即可端到端跑通。
- **ollama**：`"provider": "ollama"`，配置 `ollama.baseUrl`（默认 `http://127.0.0.1:11434`）与 `ollama.model`。调 `/api/chat`，payload 抽取步骤把该分类的 `payloadSchema` 作为 `format` 约束 JSON 输出。

## 处理管线

`src/pipeline.ts`：contentHash 去重 → provider 分类+抽取 → 相对时间以 `postedAt` 为基准解析为绝对毫秒 → 优先级缺省回退注册表 `defaultPriority` → ajv 按注册表 `payloadSchema` 校验 payload（失败降级为 generic，原 payload 平铺进 `fields`，并记录 warning）→ 同分类且标题高度相似的消息归并 `rawMessageIds`。结果追加持久化到 `data/items.jsonl`。

## 目录

```
config/default.json   默认配置（CLI 可用 config/local.json 覆盖，git 忽略）
data/                 CLI 运行期数据（pairing.json / items.jsonl / hashes.json / registry.json，git 忽略）
assets/               托盘/应用图标（npm run icons 生成）
scripts/make-icons.mjs 图标生成脚本
src/                  index.ts(CLI) connect.ts(开发用连接看护) electron-main.ts(托盘主进程) adb.ts config.ts server.ts auth.ts registry.ts pipeline.ts store.ts types.ts ai/
```

## 已知限制

- mock 的时间解析只覆盖常见中文表达（今天/明天/后天/HH:mm/x小时后/x分钟内/x月x日）。
- Ollama 的 `format` 对含 `$ref` 的 payloadSchema 支持取决于模型/版本，若输出不合规，管线会自动降级为 generic。
- 结果存储为 JSONL 追加文件，无索引，量大后 `/api/items` 会变慢。

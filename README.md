# MsgRepo

手机通知收集 + 电脑本地 AI 结构化整理系统。

手机端（Flutter/Android）收集所有通知并支持手动添加图片、文件、小程序等附件（只存访问方式）；通过 USB ADB 通道把原始消息和分类注册表（仅结构，不含内容）发给电脑端；电脑端（TypeScript/Node）调用本地 AI 模型（Ollama / OpenAI 兼容 API），把消息筛选整理为结构化的日程、待办、笔记等，送回手机端展示并按时提醒。

**数据不出本机**：传输走 USB，AI 推理在本地。

## 快速开始

```bash
# 1. 电脑端
cd desktop
npm install
npm start            # 首次启动会打印配对 token

# 2. 连接手机（开启 USB 调试）
adb forward tcp:8765 tcp:8765

# 3. 手机端（需要 Flutter SDK）
cd mobile
flutter pub get
flutter run          # 安装后：授予通知读取权限 → 设置页输入 token → 连接测试

# 无 AI 模型也能体验：默认 provider=mock（规则引擎）
npm run demo         # 在 desktop/ 下跑端到端演示
```

电脑端仪表盘：`http://127.0.0.1:8765/dashboard`

## 文档

| 文档 | 内容 |
|---|---|
| [docs/data-model.md](docs/data-model.md) | **核心**：结构化数据设计（RawMessage / StructuredItem / CategoryRegistry） |
| [docs/architecture.md](docs/architecture.md) | 总体架构与两端职责 |
| [docs/protocol.md](docs/protocol.md) | 同步协议（端点、配对认证、版本协商、重试） |
| [docs/ai-pipeline.md](docs/ai-pipeline.md) | AI 处理管线与提示词策略 |
| [docs/extensibility.md](docs/extensibility.md) | 新增分类 / 接入新 AI / 无线连接等扩展指南 |

## 数据设计一分钟速览

- **RawMessage**：原始消息，附件只存访问方式（路径/URI/小程序路径），`contentHash` 去重；采集层支持按应用过滤（全部 / 仅指定应用）
- **StructuredItem**：统一信封（`category` / `priority` P0–P3 / `confidence` / 统一时间结构 `time`）+ 分类 `payload`；手机端提醒只读 `time`
- **CategoryRegistry**：分类注册表，声明式 JSON，同步时发给电脑作为 AI 分类依据；`schedule`/`todo`/`note` 为特殊化结构，其余分类走通用 `fields` 键值表结构，**新增分类零代码改动**
- AI 输出经注册表 schema 校验，失败自动降级为 `generic` 且信息不丢

## 当前状态

核心可运行骨架。电脑端含完整管线 + Mock/Ollama/OpenAI 兼容三个 AI 适配器 + 仪表盘；手机端含通知监听、手动添加、同步、展示、提醒的完整实现（需自行安装 Flutter SDK 构建）。

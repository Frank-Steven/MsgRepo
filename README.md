# MsgRepo

手机通知采集 + 本地 AI 评估的日程/待办应用。

核心理念（设计 v2）：**日程表与待办清单的结合是应用本体，消息只是数据源，AI 是可从手机端插拔的处理服务。**

- **手机端**（Flutter/Android）持有全部数据与全部 UI：任务（年/月/日三视图日程 + 按时间尺度分页的待办）、三级笔记、消息列表、撤销队列、本地提醒、AI 客户端（路由 + 流式）。
- **电脑端 AndroidLocAI**（Electron 状态栏应用）：本地 AI 统一接口（AI 网关）——模型列表与配置（`GET /v1/models`）、统一对话接口（`POST /v1/chat`，SSE 透传）、维护 adb 通道。无业务数据、无 dashboard、不解析不执行 AI 工具调用。
- **AI 路由**：手机检测到电脑端在线（health 探测）→ 用电脑端模型（USB adb 通道，自动配对零配置）；否则用设置中配置的远程 OpenAI 兼容 API。
- **数据不出本机**：USB 物理通道即信任；AI 推理在本地或用户自选的远程 API。

## 目录结构

```
mobile/    手机端（Flutter，Android；包名 msgrepo_mobile）
desktop/   电脑端 AndroidLocAI（Electron 状态栏应用 + 本地 AI 网关，TypeScript）
shared/    两端共享的分类注册表与 JSON Schema（历史协议资产）
docs/      设计文档（现行设计见 docs/design-v2.md）
```

## 构建运行

手机端（需要 Flutter SDK 与 Android 工具链）：

```bash
cd mobile
flutter pub get
flutter test                  # 单元/widget 测试
flutter build apk --debug     # 出 debug 包
flutter run                   # 真机/模拟器运行
```

电脑端（需要 Node.js）：

```bash
cd desktop
npm install
npm run connect    # adb reverse 通道看护（自动重连）
npm run electron   # 状态栏托盘应用（开发期）
npm run dist       # 打包 macOS dmg（electron-builder）
```

## 文档

| 文档 | 内容 |
|---|---|
| [docs/design-v2.md](docs/design-v2.md) | **现行设计**（数据模型、日程/待办/笔记/消息四模块、AI 路由、UI 规范、修订记录） |
| [docs/refactor-v2.md](docs/refactor-v2.md) | v1 → v2 重构操作记录（分阶段 commit） |
| docs/architecture.md / data-model.md / protocol.md / ai-pipeline.md / extensibility.md | v1 历史文档，已被 design-v2 取代，保留作参考 |

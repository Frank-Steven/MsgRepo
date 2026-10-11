import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { DESKTOP_ROOT, loadRegistry } from "./registry.js";
import { loadOrCreatePairing } from "./auth.js";
import { Store } from "./store.js";
import { createServer } from "./server.js";
import { runPipeline } from "./pipeline.js";
import { loadConfig, type Config } from "./config.js";
import type { AIProvider } from "./ai/provider.js";
import { MockProvider } from "./ai/mock.js";
import { OllamaProvider } from "./ai/ollama.js";
import { OpenAICompatProvider } from "./ai/openai-compat.js";
import type { RawMessage, StructuredItem } from "./types.js";

const DATA_DIR = path.join(DESKTOP_ROOT, "data");

function createProvider(cfg: Config): AIProvider {
  switch (cfg.provider) {
    case "ollama":
      return new OllamaProvider(cfg.ollama);
    case "openai-compatible":
      return new OpenAICompatProvider({
        ...cfg.openai,
        apiKey: process.env[cfg.openai.apiKeyEnv],
      });
    default:
      return new MockProvider();
  }
}

function contentHash(packageName: string, title: string, body: string, postedAt: number): string {
  return createHash("sha256").update(`${packageName}|${title}|${body}|${postedAt}`).digest("hex");
}

function sampleMessage(
  packageName: string,
  appName: string,
  title: string,
  body: string,
  postedAt: number,
): RawMessage {
  return {
    id: randomUUID(),
    source: { packageName, appName },
    title,
    body,
    postedAt,
    captureType: "notification",
    contentHash: contentHash(packageName, title, body, postedAt),
    status: "pending",
  };
}

function fmtItem(item: StructuredItem): string {
  const fmt = (ms?: number) => (ms ? new Date(ms).toLocaleString("zh-CN", { hour12: false }) : "-");
  const lines = [
    `  [${item.category}] ${item.priority} 置信度=${item.confidence}  ${item.title}`,
    `    摘要: ${item.summary}`,
    `    时间: kind=${item.time.kind} startAt=${fmt(item.time.startAt)} deadline=${fmt(item.time.deadline)}` +
      ` 提醒提前=${JSON.stringify(item.time.reminderOffsets ?? [])}`,
    `    payload: ${JSON.stringify(item.payload)}`,
  ];
  return lines.join("\n");
}

async function demo(): Promise<void> {
  const registry = loadRegistry(DATA_DIR);
  const provider = new MockProvider();
  const now = Date.now();
  const samples: RawMessage[] = [
    sampleMessage(
      "com.tencent.wework", "企业微信", "产品评审会",
      "【会议通知】明天下午3点 产品评审会，在 3F 大会议室，请准时参加", now - 60_000),
    sampleMessage(
      "com.cainiao.wireless", "菜鸟", "包裹到站",
      "您的包裹已到达菜鸟驿站，取件码 6-1-2345，请凭取件码取件", now - 3_600_000),
    sampleMessage(
      "com.android.mms", "信息", "【阿里云】",
      "验证码 483920，5 分钟内有效，请勿泄露给他人", now - 120_000),
    sampleMessage(
      "com.cmbchina.cc", "掌上生活", "信用卡账单",
      "本期账单 ¥128.50，最后还款日 10月25日，请及时还款", now - 86_400_000),
    sampleMessage(
      "com.taobao.taobao", "淘宝", "限时促销",
      "限时优惠！全场满300减50，仅限今天，速来抢购", now - 7_200_000),
    sampleMessage(
      "com.tencent.mm", "微信", "羽毛球群",
      "周末有人打球吗？老地方见", now - 400_000),
  ];

  console.log(`== MsgRepo demo（provider=${provider.name}, registry v${registry.version}）==\n`);
  console.log(`输入 ${samples.length} 条示例消息：`);
  for (const m of samples) console.log(`  - [${m.source.appName}] ${m.title}: ${m.body}`);

  // demo 不写磁盘（不传 store），完整走管线：分类→抽取→时间解析→优先级→payload 校验→归并
  const result = await runPipeline(samples, registry, provider);

  console.log(`\n== 产出 ${result.results.length} 条 StructuredItem（payload 均已通过注册表 payloadSchema 校验）==\n`);
  for (const item of result.results) console.log(fmtItem(item) + "\n");

  console.log(`== 管线结果 ==`);
  console.log(`  processedMessageIds: ${result.processedMessageIds.length} 条`);
  console.log(`  failedMessageIds: ${result.failedMessageIds.length} 条`);
  if (result.warnings.length > 0) {
    console.log(`  warnings:`);
    for (const w of result.warnings) console.log(`    - ${w}`);
  } else {
    console.log(`  warnings: 无（全部校验通过，无降级/归并）`);
  }
}

async function main(): Promise<void> {
  const cmd = process.argv[2] ?? "start";

  if (cmd === "pair") {
    const { pairing, created } = loadOrCreatePairing(DATA_DIR);
    console.log(`配对 token${created ? "（新生成）" : ""}: ${pairing.token}`);
    console.log(`手机端请使用请求头: Authorization: Bearer ${pairing.token}`);
    return;
  }

  if (cmd === "demo") {
    await demo();
    return;
  }

  if (cmd !== "start") {
    console.error(`未知命令: ${cmd}（可用: start | pair | demo）`);
    process.exit(1);
  }

  const cfg = loadConfig();
  const provider = createProvider(cfg);
  const { pairing, created } = loadOrCreatePairing(DATA_DIR);
  const store = new Store(DATA_DIR);
  const server = createServer({
    host: cfg.host,
    port: cfg.port,
    token: pairing.token,
    provider,
    store,
    dataDir: DATA_DIR,
  });
  server.listen(cfg.port, cfg.host, () => {
    console.log(`MsgRepo desktop 已启动: http://${cfg.host}:${cfg.port}`);
    console.log(`AI provider: ${provider.name}${provider.model ? ` (${provider.model})` : ""}`);
    if (created) {
      console.log(`\n首次启动，已生成配对 token: ${pairing.token}`);
      console.log(`手机端请使用请求头: Authorization: Bearer ${pairing.token}\n`);
    } else {
      console.log(`配对 token 已存在（运行 \`npm run pair\` 查看）`);
    }
    console.log(`仪表盘: http://${cfg.host}:${cfg.port}/dashboard`);
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

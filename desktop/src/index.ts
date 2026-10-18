import path from "node:path";
import { DESKTOP_ROOT } from "./registry.js";
import { loadOrCreatePairing, PairingManager } from "./auth.js";
import { createServer } from "./server.js";
import { loadConfig } from "./config.js";
import { createProvider } from "./ai/factory.js";

// P3-12：v1 的 demo 命令（runPipeline + MockProvider + StructuredItem）随 v1 管线一并移除；
// 现在只剩 start（起服务）与 pair（查看配对 token）。
const DATA_DIR = path.join(DESKTOP_ROOT, "data");

async function main(): Promise<void> {
  const cmd = process.argv[2] ?? "start";

  if (cmd === "pair") {
    const { pairing, created } = loadOrCreatePairing(DATA_DIR);
    console.log(`配对 token${created ? "（新生成）" : ""}: ${pairing.token}`);
    console.log(`手机端请使用请求头: Authorization: Bearer ${pairing.token}`);
    return;
  }

  if (cmd !== "start") {
    console.error(`未知命令: ${cmd}（可用: start | pair）`);
    process.exit(1);
  }

  const cfg = loadConfig();
  const provider = createProvider(cfg);
  const pairing = new PairingManager(DATA_DIR);
  const server = createServer({
    host: cfg.host,
    port: cfg.port,
    pairing,
    provider,
    dataDir: DATA_DIR,
  });
  server.listen(cfg.port, cfg.host, () => {
    console.log(`MsgRepo desktop 已启动: http://${cfg.host}:${cfg.port}`);
    console.log(`AI provider: ${provider.name}${provider.model ? ` (${provider.model})` : ""}`);
    if (pairing.created) {
      console.log(`\n首次启动，已生成配对 token: ${pairing.token}`);
      console.log(`手机端请使用请求头: Authorization: Bearer ${pairing.token}\n`);
    } else {
      console.log(`配对 token 已存在（运行 \`npm run pair\` 查看）`);
    }
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

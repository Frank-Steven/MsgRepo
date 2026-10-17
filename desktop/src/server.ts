import http from "node:http";
import os from "node:os";
import { Ajv2020 } from "ajv/dist/2020.js";
import { isAuthorized, type PairingManager } from "./auth.js";
import { GateBusyError, SerialGate } from "./limit.js";
import { loadRegistry, negotiateRegistry, readSharedJson } from "./registry.js";
import { processStreaming, runPipeline } from "./pipeline.js";
import type { Store } from "./store.js";
import type { AIProvider } from "./ai/provider.js";
import type {
  ProcessInputMessage,
  ProcessRequestBody,
  SyncRequest,
  SyncResponse,
} from "./types.js";

export interface ServerOptions {
  host: string;
  port: number;
  pairing: PairingManager;
  provider: AIProvider;
  store: Store;
  dataDir: string;
}

const MAX_BODY = 20 * 1024 * 1024;

/** /v1/process 请求体的最小校验：messages 非空数组，元素至少含 id/title。 */
function parseProcessRequest(raw: unknown): ProcessRequestBody | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  if (!Array.isArray(o.messages) || o.messages.length === 0) return null;
  const messages: ProcessInputMessage[] = [];
  for (const m of o.messages) {
    if (!m || typeof m !== "object") return null;
    const r = m as Record<string, unknown>;
    if (typeof r.id !== "string" || typeof r.title !== "string") return null;
    messages.push({
      id: r.id,
      title: r.title,
      body: typeof r.body === "string" ? r.body : "",
      appName: typeof r.appName === "string" ? r.appName : undefined,
      conversationTitle:
        typeof r.conversationTitle === "string" ? r.conversationTitle : undefined,
      sender: typeof r.sender === "string" ? r.sender : undefined,
      postedAt:
        typeof r.postedAt === "number" && Number.isFinite(r.postedAt)
          ? r.postedAt
          : Date.now(),
    });
  }
  return {
    messages,
    customPrompt: typeof o.customPrompt === "string" ? o.customPrompt : undefined,
    now: typeof o.now === "string" ? o.now : new Date().toISOString(),
    timezone: typeof o.timezone === "string" ? o.timezone : undefined,
  };
}

function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function sendJson(res: http.ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(body));
}

const DASHBOARD_HTML = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MsgRepo 仪表盘</title>
<style>
  body { font-family: -apple-system, "PingFang SC", sans-serif; margin: 0; background: #f5f6f8; color: #222; }
  header { background: #1f2937; color: #fff; padding: 12px 20px; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
  header h1 { font-size: 16px; margin: 0; }
  header input, header select { padding: 4px 8px; border-radius: 4px; border: 1px solid #ccc; }
  header button { padding: 4px 12px; border: 0; border-radius: 4px; background: #2563eb; color: #fff; cursor: pointer; }
  main { padding: 16px 20px; }
  .card { background: #fff; border-radius: 8px; padding: 12px 16px; margin-bottom: 10px; box-shadow: 0 1px 2px rgba(0,0,0,.06); }
  .meta { font-size: 12px; color: #666; margin-top: 4px; display: flex; gap: 8px; flex-wrap: wrap; }
  .badge { display: inline-block; padding: 1px 8px; border-radius: 10px; font-size: 12px; background: #e5e7eb; }
  .P0 { background: #fecaca; } .P1 { background: #fed7aa; } .P2 { background: #dbeafe; } .P3 { background: #e5e7eb; }
  pre { background: #f3f4f6; padding: 8px; border-radius: 4px; font-size: 12px; overflow: auto; }
  #status { font-size: 13px; color: #666; }
</style>
</head>
<body>
<header>
  <h1>MsgRepo 仪表盘</h1>
  <input id="token" placeholder="配对 token" size="28">
  <select id="category"><option value="">全部分类</option></select>
  <select id="priority">
    <option value="">全部优先级</option>
    <option>P0</option><option>P1</option><option>P2</option><option>P3</option>
  </select>
  <button id="reload">刷新</button>
  <span id="status"></span>
</header>
<main id="list"></main>
<script>
const tokenInput = document.getElementById("token");
tokenInput.value = localStorage.getItem("msgrepo_token") || "";
tokenInput.addEventListener("change", () => localStorage.setItem("msgrepo_token", tokenInput.value));

function fmtTime(t) {
  if (!t || t.kind === "none") return "无时间";
  const f = (ms) => new Date(ms).toLocaleString("zh-CN", { hour12: false });
  const parts = [t.kind];
  if (t.startAt) parts.push("开始 " + f(t.startAt));
  if (t.endAt) parts.push("结束 " + f(t.endAt));
  if (t.deadline) parts.push("截止 " + f(t.deadline));
  return parts.join(" · ");
}

async function load() {
  const status = document.getElementById("status");
  const list = document.getElementById("list");
  const params = new URLSearchParams();
  const cat = document.getElementById("category").value;
  const pri = document.getElementById("priority").value;
  if (cat) params.set("category", cat);
  if (pri) params.set("priority", pri);
  try {
    const res = await fetch("/api/items?" + params, {
      headers: { Authorization: "Bearer " + tokenInput.value },
    });
    if (res.status === 401) { status.textContent = "token 无效，请填入配对 token"; list.innerHTML = ""; return; }
    if (!res.ok) throw new Error("HTTP " + res.status);
    const data = await res.json();
    status.textContent = "共 " + data.total + " 条";
    const catSel = document.getElementById("category");
    const known = new Set([...catSel.options].map((o) => o.value));
    list.innerHTML = "";
    for (const item of data.items.slice().reverse()) {
      if (!known.has(item.category)) {
        const opt = document.createElement("option");
        opt.value = item.category; opt.textContent = item.category;
        catSel.appendChild(opt); known.add(item.category);
      }
      const div = document.createElement("div");
      div.className = "card";
      const h = document.createElement("div");
      const title = document.createElement("strong"); title.textContent = item.title;
      h.appendChild(title);
      const meta = document.createElement("div");
      meta.className = "meta";
      const badges = [[item.priority, "badge " + item.priority], [item.category, "badge"],
        ["置信度 " + item.confidence, "badge"], [fmtTime(item.time), "badge"],
        ["by " + item.processedBy.provider, "badge"]];
      for (const [text, cls] of badges) {
        const s = document.createElement("span"); s.className = cls; s.textContent = text; meta.appendChild(s);
      }
      const summary = document.createElement("div");
      summary.className = "meta"; summary.textContent = item.summary;
      const pre = document.createElement("pre");
      pre.textContent = JSON.stringify(item.payload, null, 2);
      div.append(h, meta, summary, pre);
      list.appendChild(div);
    }
  } catch (e) {
    status.textContent = "加载失败: " + e;
  }
}
document.getElementById("reload").addEventListener("click", load);
document.getElementById("category").addEventListener("change", load);
document.getElementById("priority").addEventListener("change", load);
load();
</script>
</body>
</html>
`;

/** 需要串行化的推理端点（都直接调用本地/远程模型）。 */
const GATED_PATHS = new Set(["/v1/process", "/v1/sync"]);

export function createServer(opts: ServerOptions): http.Server {
  // 注册 shared schemas，使 sync-request 内的相对 $ref 可解析
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  for (const name of ["raw-message", "category-registry", "structured-item", "sync-request"]) {
    ajv.addSchema(readSharedJson(`schemas/${name}.schema.json`) as object);
  }
  // 并发闸（P2-4）：默认同时只跑 1 个推理请求，最多排 8 个，再多直接 429
  const processGate = new SerialGate(1, 8);

  const validateSyncRequest = ajv.getSchema("https://msgrepo.dev/schemas/sync-request.schema.json");
  if (!validateSyncRequest) throw new Error("sync-request schema 加载失败");

  return http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
      const pathname = url.pathname;

      // 推理端点串行化（P2-4）：多个手机/手动请求并发会打满本地模型进程。
      // 槽位在响应结束时释放（close 覆盖正常完成与客户端断开两种情况）。
      if (GATED_PATHS.has(pathname)) {
        let releaseSlot: (() => void) | null = null;
        try {
          releaseSlot = await processGate.acquireSlot();
        } catch (e) {
          if (e instanceof GateBusyError) {
            res.setHeader("Retry-After", "5");
            return sendJson(res, 429, { error: "busy", retryAfter: 5 });
          }
          throw e;
        }
        res.on("close", () => releaseSlot?.());
      }

      // 免认证
      if (req.method === "GET" && pathname === "/v1/health") {
        return sendJson(res, 200, {
          status: "ok",
          provider: opts.provider.name,
          time: Date.now(),
        });
      }
      // 自动配对（设计 §11）：免认证——server 只监听 loopback，USB 物理通道即信任。
      // 无 body 返回当前 token；{"reset":true} 重新签发。手机端 401 时自动调一次。
      if (req.method === "POST" && pathname === "/v1/pair") {
        const raw = await readBody(req);
        let body: unknown = {};
        if (raw.trim()) {
          try {
            body = JSON.parse(raw);
          } catch {
            return sendJson(res, 400, { error: "invalid JSON body" });
          }
        }
        if ((body as { reset?: unknown }).reset === true) opts.pairing.reset();
        return sendJson(res, 200, {
          token: opts.pairing.token,
          deviceName: os.hostname(),
        });
      }
      if (req.method === "GET" && (pathname === "/dashboard" || pathname === "/")) {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        return res.end(DASHBOARD_HTML);
      }

      // 以下端点需要配对 token
      if (req.method === "GET" && pathname === "/api/items") {
        if (!isAuthorized(req, opts.pairing.token))
          return sendJson(res, 401, { error: "unauthorized" });
        const items = opts.store.listItems({
          category: url.searchParams.get("category") ?? undefined,
          priority: url.searchParams.get("priority") ?? undefined,
        });
        return sendJson(res, 200, { total: items.length, items });
      }

      // v2 流式评估（设计 §8/§12）：NDJSON，每行一个 token/result/error 事件，done 收尾
      if (req.method === "POST" && pathname === "/v1/process") {
        if (!isAuthorized(req, opts.pairing.token))
          return sendJson(res, 401, { error: "unauthorized" });
        let parsed: unknown;
        try {
          parsed = JSON.parse(await readBody(req));
        } catch {
          return sendJson(res, 400, { error: "invalid JSON body" });
        }
        const body = parseProcessRequest(parsed);
        if (!body) {
          return sendJson(res, 400, {
            error: "invalid process request: messages 必须是非空数组，元素至少含 id/title",
          });
        }
        const parsedNow = Date.parse(body.now.replace(" ", "T"));
        const now = Number.isNaN(parsedNow) ? Date.now() : parsedNow;
        const startedAt = Date.now();
        console.log(`[process] 收到 ${body.messages.length} 条消息，开始流式评估…`);
        res.writeHead(200, {
          "Content-Type": "application/x-ndjson; charset=utf-8",
          "Cache-Control": "no-cache",
          "X-Accel-Buffering": "no",
        });
        // 立即冲刷响应头：处理可能耗时数十秒，客户端对建立连接有超时限制
        res.flushHeaders();
        const send = (obj: unknown) => {
          try {
            res.write(JSON.stringify(obj) + "\n");
          } catch {
            // 客户端已断开：忽略写入错误，剩余消息继续处理
          }
        };
        const registry = loadRegistry(opts.dataDir);
        const result = await processStreaming(body.messages, registry, opts.provider, {
          customPrompt: body.customPrompt,
          now,
          onEvent: send,
        });
        send({ type: "done", total: result.total, failed: result.failed });
        res.end();
        console.log(
          `[process] 完成：${result.total} 条 / 失败 ${result.failed}，` +
            `耗时 ${((Date.now() - startedAt) / 1000).toFixed(1)}s`,
        );
        return;
      }

      // Deprecated：v1 同步协议，保留一个版本周期供旧手机端使用（设计 §12），新端点为 /v1/process
      if (req.method === "POST" && pathname === "/v1/sync") {
        res.setHeader("Deprecation", "true");
        if (!isAuthorized(req, opts.pairing.token))
          return sendJson(res, 401, { error: "unauthorized" });
        let parsed: unknown;
        try {
          parsed = JSON.parse(await readBody(req));
        } catch {
          return sendJson(res, 400, { error: "invalid JSON body" });
        }
        if (!validateSyncRequest(parsed)) {
          return sendJson(res, 400, {
            error: "request failed sync-request schema validation",
            details: ajv.errorsText(validateSyncRequest.errors),
          });
        }
        const syncReq = parsed as SyncRequest;
        const startedAt = Date.now();
        console.log(`[sync] 收到 ${syncReq.messages.length} 条消息（stream=${syncReq.stream === true}），开始处理…`);
        const current = loadRegistry(opts.dataDir);
        const { registry, warnings: regWarnings } = negotiateRegistry(syncReq, current, opts.dataDir);

        // 流式模式：NDJSON 逐条下发进度，每条结果在管线内已即时落盘
        if (syncReq.stream === true) {
          res.writeHead(200, {
            "Content-Type": "application/x-ndjson; charset=utf-8",
            "Cache-Control": "no-cache",
          });
          const send = (obj: unknown) => {
            try {
              res.write(JSON.stringify(obj) + "\n");
            } catch {
              // 客户端已断开：忽略写入错误，管线继续落盘
            }
          };
          for (const w of regWarnings) send({ type: "warning", message: w });
          const result = await runPipeline(syncReq.messages, registry, opts.provider, opts.store, {
            customPrompt: syncReq.customPrompt,
            reprocessMessageIds: syncReq.reprocessMessageIds,
            onProgress: (ev) => send({ type: "progress", ...ev }),
          });
          console.log(
            `[sync] 完成：${result.processedMessageIds.length} 处理 / ${result.failedMessageIds.length} 失败 / ` +
              `${result.results.length} 条结果，耗时 ${((Date.now() - startedAt) / 1000).toFixed(1)}s`,
          );
          send({
            type: "done",
            registryVersion: registry.version,
            failedMessageIds: result.failedMessageIds,
            warnings: result.warnings,
          });
          res.end();
          return;
        }

        const result = await runPipeline(syncReq.messages, registry, opts.provider, opts.store, {
          customPrompt: syncReq.customPrompt,
          reprocessMessageIds: syncReq.reprocessMessageIds,
        });
        console.log(
          `[sync] 完成：${result.processedMessageIds.length} 处理 / ${result.failedMessageIds.length} 失败 / ` +
            `${result.results.length} 条结果，耗时 ${((Date.now() - startedAt) / 1000).toFixed(1)}s`,
        );
        const response: SyncResponse = {
          registryVersion: registry.version,
          results: result.results,
          processedMessageIds: result.processedMessageIds,
          failedMessageIds: result.failedMessageIds,
          warnings: [...regWarnings, ...result.warnings],
        };
        return sendJson(res, 200, response);
      }

      sendJson(res, 404, { error: "not found" });
    } catch (err) {
      sendJson(res, 500, { error: String(err) });
    }
  });
}

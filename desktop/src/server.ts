import http from "node:http";
import os from "node:os";
import { Ajv2020 } from "ajv/dist/2020.js";
import { isAuthorized, type PairingManager } from "./auth.js";
import { GateBusyError, SerialGate } from "./limit.js";
import { loadRegistry, readSharedJson } from "./registry.js";
import { processStreaming } from "./pipeline.js";
import type { AIProvider } from "./ai/provider.js";
import type {
  ProcessInputMessage,
  ProcessRequestBody,


} from "./types.js";

export interface ServerOptions {
  host: string;
  port: number;
  pairing: PairingManager;
  provider: AIProvider;
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


/** 需要串行化的推理端点（都直接调用本地/远程模型）。 */
const GATED_PATHS = new Set(["/v1/process"]);

export function createServer(opts: ServerOptions): http.Server {
  // 注册 shared schemas，使 sync-request 内的相对 $ref 可解析
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  for (const name of ["category-registry"]) {
    ajv.addSchema(readSharedJson(`schemas/${name}.schema.json`) as object);
  }
  // 并发闸（P2-4）：默认同时只跑 1 个推理请求，最多排 8 个，再多直接 429
  const processGate = new SerialGate(1, 8);


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
        if ((body as { reset?: unknown }).reset === true) {
          // P2-2：重置 token 必须证明持有当前 token。此前任何人都能在 loopback 上把
          // 手机踢下线（或诱导手机重新配对到本机攻击者进程）。首次配对不走 reset，
          // 因此「USB 即信任、不输入 token」的零配置体验不受影响。
          if (!isAuthorized(req, opts.pairing.token)) {
            return sendJson(res, 403, { error: "reset requires current token" });
          }
          opts.pairing.reset();
        }
        return sendJson(res, 200, {
          token: opts.pairing.token,
          deviceName: os.hostname(),
        });
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

      sendJson(res, 404, { error: "not found" });
    } catch (err) {
      sendJson(res, 500, { error: String(err) });
    }
  });
}

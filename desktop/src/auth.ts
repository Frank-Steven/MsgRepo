import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";
import type { IncomingMessage } from "node:http";

export interface Pairing {
  token: string;
  createdAt: number;
}

/** 首次启动生成随机 token 写入 data/pairing.json；已存在则直接加载。 */
export function loadOrCreatePairing(dataDir: string): { pairing: Pairing; created: boolean } {
  mkdirSync(dataDir, { recursive: true });
  const file = path.join(dataDir, "pairing.json");
  if (existsSync(file)) {
    try {
      const parsed = JSON.parse(readFileSync(file, "utf8")) as Pairing;
      if (parsed && typeof parsed.token === "string" && parsed.token.length > 0) {
        return { pairing: parsed, created: false };
      }
    } catch {
      // 文件损坏则重新生成
    }
  }
  const pairing: Pairing = { token: randomBytes(24).toString("base64url"), createdAt: Date.now() };
  writeFileSync(file, JSON.stringify(pairing, null, 2), { mode: 0o600 });
  return { pairing, created: true };
}

/** 校验 Authorization: Bearer <token>。 */
export function isAuthorized(req: IncomingMessage, token: string): boolean {
  return req.headers.authorization === `Bearer ${token}`;
}

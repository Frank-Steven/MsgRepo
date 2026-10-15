import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

/**
 * adb 通道维护：connect.ts CLI 与 Electron 托盘共用。
 * 无设备/未授权时静默返回状态，由调用方决定是否提示。
 * 打包 App 从 Finder 启动时 PATH 不含 Homebrew，因此先解析 adb 绝对路径再执行。
 */

export type DeviceState = "ok" | "unauthorized" | "absent";

export interface DeviceInfo {
  serial: string;
  model: string;
}

let resolvedAdb: string | null | undefined;

/** 解析 adb 可执行文件路径：先 PATH，再常见安装位置；找不到缓存 null（下次调用重新探测）。 */
export async function adbPath(): Promise<string | null> {
  if (resolvedAdb !== undefined && resolvedAdb !== null) return resolvedAdb;
  try {
    await run("adb", ["version"]);
    resolvedAdb = "adb";
    return resolvedAdb;
  } catch {
    // PATH 上没有，继续找常见位置
  }
  const candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"];
  const androidHome = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT;
  if (androidHome) candidates.unshift(path.join(androidHome, "platform-tools", "adb"));
  candidates.push(path.join(os.homedir(), "Library", "Android", "sdk", "platform-tools", "adb"));
  for (const c of candidates) {
    if (existsSync(c)) {
      resolvedAdb = c;
      return c;
    }
  }
  resolvedAdb = null;
  return null;
}

async function adb(args: string[]): Promise<string> {
  const bin = await adbPath();
  if (!bin) throw new Error("adb 未安装");
  const { stdout } = await run(bin, args);
  return stdout;
}

/** 已授权设备列表（含型号/序列号）；adb 缺失或无设备时返回空数组。 */
export async function listDevices(): Promise<DeviceInfo[]> {
  try {
    const out = await adb(["devices", "-l"]);
    const devices: DeviceInfo[] = [];
    for (const line of out.trim().split("\n").slice(1)) {
      if (!line.includes("\tdevice")) continue;
      const serial = line.split("\t")[0]!.trim();
      const modelMatch = /\bmodel:([^\s]+)/.exec(line);
      devices.push({ serial, model: modelMatch?.[1] ?? "未知型号" });
    }
    return devices;
  } catch {
    return [];
  }
}

export async function deviceState(): Promise<DeviceState> {
  try {
    const out = await adb(["devices"]);
    const lines = out.trim().split("\n").slice(1);
    for (const line of lines) {
      if (line.includes("\tdevice")) return "ok";
      if (line.includes("unauthorized")) return "unauthorized";
    }
    return "absent";
  } catch {
    return "absent";
  }
}

export async function reverseEstablished(port: number): Promise<boolean> {
  try {
    const out = await adb(["reverse", "--list"]);
    return out.includes(`tcp:${port}`);
  } catch {
    return false;
  }
}

/** 确保 adb reverse tcp:port 存在；已存在直接返回 true，失败返回 false（不抛异常）。 */
export async function ensureReverse(port: number): Promise<boolean> {
  if (await reverseEstablished(port)) return true;
  try {
    await adb(["reverse", `tcp:${port}`, `tcp:${port}`]);
    return await reverseEstablished(port);
  } catch {
    return false;
  }
}

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

/** adb 通道维护：connect.ts CLI 与 Electron 托盘共用。无设备/未授权时静默返回状态，由调用方决定是否提示。 */

export type DeviceState = "ok" | "unauthorized" | "absent";

export async function deviceState(): Promise<DeviceState> {
  try {
    const { stdout } = await run("adb", ["devices"]);
    const lines = stdout.trim().split("\n").slice(1);
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
    const { stdout } = await run("adb", ["reverse", "--list"]);
    return stdout.includes(`tcp:${port}`);
  } catch {
    return false;
  }
}

/** 确保 adb reverse tcp:port 存在；已存在直接返回 true，失败返回 false（不抛异常）。 */
export async function ensureReverse(port: number): Promise<boolean> {
  if (await reverseEstablished(port)) return true;
  try {
    await run("adb", ["reverse", `tcp:${port}`, `tcp:${port}`]);
    return await reverseEstablished(port);
  } catch {
    return false;
  }
}

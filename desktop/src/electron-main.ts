import { app, Tray, Menu, Notification, nativeImage, clipboard, shell } from "electron";
import type { Server } from "node:http";
import path from "node:path";
import { loadConfig } from "./config.js";
import { DESKTOP_ROOT } from "./registry.js";
import { PairingManager } from "./auth.js";
import { Store } from "./store.js";
import { createServer } from "./server.js";
import { createProvider } from "./ai/factory.js";
import {
  adbPath,
  deviceState,
  ensureReverse,
  listDevices,
  type DeviceInfo,
  type DeviceState,
} from "./adb.js";

/**
 * macOS 状态栏托盘主进程（设计 §11）：无 Dock 图标、无主窗口、无控制台依赖。
 * 启动即完成全部连接工作：内嵌 HTTP 服务（:8765）→ 探测 adb → 自动 adb reverse →
 * 5 秒看护（断线重连 / 设备插拔识别 / 服务掉线重拉）。
 * 用户可见的状态全部在托盘菜单与系统通知里呈现。
 */

// 固定应用名，保证 userData 目录稳定为 ~/Library/Application Support/MsgRepo
app.setName("MsgRepo");

// 配置：包内 default.json → 包内 local.json（仅开发）→ userData/config.json（用户覆盖）
const USER_CONFIG = path.join(app.getPath("userData"), "config.json");
const cfg = loadConfig([USER_CONFIG]);
const PORT = cfg.port;
const HOST = cfg.host;
const BASE_URL = `http://${HOST}:${PORT}`;
const ADB_INSTALL_CMD = "brew install android-platform-tools";
const ADB_DOWNLOAD_URL = "https://developer.android.com/tools/releases/platform-tools";

type ServerStatus = "starting" | "running" | "reused" | "error";
type AiStatus = "ok" | "down" | "na"; // na = 内置规则引擎，无需后端

let server: Server | null = null;
let tray: Tray | null = null;
let pairing: PairingManager;
let providerName = "";
let providerModel = "";

let serverStatus: ServerStatus = "starting";
let serverError = "";
let adbMissing = false;
let devState: DeviceState | "" = "";
let device: DeviceInfo | null = null;
let adbReady = false;
let aiStatus: AiStatus = "na";
const events: string[] = [];

function log(msg: string): void {
  console.log(`[${new Date().toLocaleTimeString("zh-CN", { hour12: false })}] ${msg}`);
}

/** 记录事件：控制台 + 「最近事件」子菜单（保留最近 5 条）。 */
function event(msg: string): void {
  log(msg);
  events.unshift(`${new Date().toLocaleTimeString("zh-CN", { hour12: false })}  ${msg}`);
  if (events.length > 5) events.length = 5;
}

function notify(body: string): void {
  try {
    if (Notification.isSupported()) new Notification({ title: "MsgRepo", body }).show();
  } catch {
    // 未签名应用通知可能不可用，状态仍以菜单为准
  }
  event(body);
}

async function serverUp(): Promise<boolean> {
  try {
    const res = await fetch(`${BASE_URL}/v1/health`, { signal: AbortSignal.timeout(3000) });
    return res.ok;
  } catch {
    return false;
  }
}

/** 已有服务在跑（比如 CLI 起的）就直接复用，避免端口冲突；否则进程内启动。 */
async function ensureServer(): Promise<void> {
  try {
    const res = await fetch(`${BASE_URL}/v1/health`, { signal: AbortSignal.timeout(3000) });
    if (res.ok) {
      const health = (await res.json()) as { provider?: string };
      providerName = health.provider ?? "";
      // 复用外部服务时模型名未知，若 provider 与本地配置一致则沿用配置里的模型名
      if (providerName === cfg.provider) {
        providerModel = cfg.provider === "ollama" ? cfg.ollama.model : cfg.openai.model;
      }
      if (serverStatus !== "reused") {
        serverStatus = "reused";
        event(`检测到服务已在运行：${BASE_URL}（provider=${providerName}，复用，不再拉起）`);
      }
      return;
    }
  } catch {
    // 服务未运行，往下走进程内启动
  }
  if (server) return; // 本进程的服务已在跑，只是 health 暂时没响应
  const provider = createProvider(cfg);
  providerName = provider.name;
  providerModel = provider.model ?? "";
  const store = new Store(app.getPath("userData"));
  server = createServer({
    host: HOST,
    port: PORT,
    pairing,
    provider,
    store,
    dataDir: app.getPath("userData"),
  });
  try {
    await new Promise<void>((resolve, reject) => {
      server!.once("error", reject);
      server!.listen(PORT, HOST, resolve);
    });
    serverStatus = "running";
    event(`服务已启动: ${BASE_URL}（provider=${providerName}${providerModel ? ` (${providerModel})` : ""}）`);
  } catch (err) {
    server = null;
    serverStatus = "error";
    serverError = String(err).includes("EADDRINUSE")
      ? `端口 ${PORT} 被其他程序占用`
      : String(err);
    notify(`服务启动失败：${serverError}`);
  }
}

/** AI 后端连通性：llama.cpp 试 {origin}/health，OpenAI 兼容试 {baseUrl}/models，Ollama 试 /api/tags。 */
async function checkAiBackend(): Promise<boolean> {
  const base = cfg.provider === "ollama" ? cfg.ollama.baseUrl : cfg.openai.baseUrl;
  let origin: string;
  try {
    origin = new URL(base).origin;
  } catch {
    return false;
  }
  const candidates = [
    `${origin}/health`,
    `${base.replace(/\/$/, "")}/models`,
    `${origin}/api/tags`,
  ];
  for (const url of candidates) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(3000) });
      if (res.ok) return true;
    } catch {
      // 试下一个
    }
  }
  return false;
}

function aiBackendEndpoint(): string {
  const base = cfg.provider === "ollama" ? cfg.ollama.baseUrl : cfg.openai.baseUrl;
  try {
    return new URL(base).host;
  } catch {
    return base;
  }
}

function trayIcon() {
  const image = nativeImage.createFromPath(path.join(DESKTOP_ROOT, "assets", "iconTemplate.png"));
  image.setTemplateImage(true);
  return image;
}

function serverLabel(): string {
  switch (serverStatus) {
    case "running":
      return `运行中 · ${BASE_URL}`;
    case "reused":
      return `运行中（复用已有进程）· ${BASE_URL}`;
    case "error":
      return `启动失败 · ${serverError}`;
    default:
      return "启动中…";
  }
}

function aiLabel(): string {
  if (cfg.provider === "mock" && serverStatus !== "reused") return "内置规则引擎（无需模型服务）";
  const model = providerModel ? `（${providerModel}）` : "";
  switch (aiStatus) {
    case "ok":
      return `已连接 · ${aiBackendEndpoint()}${model}`;
    case "down":
      return `不可达 · ${aiBackendEndpoint()}（手机端将走远程 API）`;
    default:
      return "检测中…";
  }
}

function deviceLabel(): string {
  if (adbMissing) return "未检测到 adb（无法连接手机）";
  switch (devState) {
    case "ok": {
      const d = device ? `${device.model}（${device.serial}）` : "已连接";
      return adbReady ? `${d} · 通道就绪` : `${d} · 通道重建中…`;
    }
    case "unauthorized":
      return "已连接，待手机授权 USB 调试";
    case "absent":
      return "未连接";
    default:
      return "检测中…";
  }
}

function rebuildMenu(): void {
  if (!tray) return;
  const token = pairing.token;
  const template: Electron.MenuItemConstructorOptions[] = [
    { label: "MsgRepo（电脑端 AI 服务）", enabled: false },
    { type: "separator" },
    { label: `服务：${serverLabel()}`, enabled: false },
    { label: `AI 后端：${aiLabel()}`, enabled: false },
    { label: `手机：${deviceLabel()}`, enabled: false },
  ];
  if (adbMissing) {
    template.push(
      {
        label: "安装 adb：复制安装命令",
        click: () => {
          clipboard.writeText(ADB_INSTALL_CMD);
          notify(`已复制「${ADB_INSTALL_CMD}」，在终端执行后重启本应用即可`);
        },
      },
      { label: "adb 下载页（Android Platform Tools）", click: () => void shell.openExternal(ADB_DOWNLOAD_URL) },
    );
  }
  template.push(
    {
      label: "最近事件",
      submenu:
        events.length > 0
          ? events.map((e) => ({ label: e, enabled: false }))
          : [{ label: "（暂无）", enabled: false }],
    },
    { type: "separator" },
    { label: `配对码：${token.slice(0, 8)}…（手机端 401 时自动配对）`, enabled: false },
    {
      label: "复制配对码",
      click: () => {
        clipboard.writeText(pairing.token);
        event("配对码已复制到剪贴板");
      },
    },
    {
      label: "重置配对码",
      click: () => {
        pairing.reset();
        rebuildMenu();
        event("配对码已重置，手机端会在 401 时自动重配");
      },
    },
    { label: "打开仪表盘", click: () => void shell.openExternal(`${BASE_URL}/dashboard`) },
    { type: "separator" },
    {
      label: "开机自启",
      type: "checkbox",
      checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => {
        app.setLoginItemSettings({ openAtLogin: item.checked });
        event(`开机自启已${item.checked ? "开启" : "关闭"}`);
      },
    },
    { type: "separator" },
    { label: "退出", click: () => app.quit() },
  );
  tray.setContextMenu(Menu.buildFromTemplate(template));
  tray.setToolTip(`MsgRepo · 手机${deviceLabel()}`);
}

/** 5 秒看护：adb 探测 → 设备识别 → reverse 通道 → AI 后端连通性 → 服务掉线重拉。
 *  状态只在变化时记事件/发通知，无设备静默重试。 */
async function tick(): Promise<void> {
  let changed = false;

  if (serverStatus === "error" || (serverStatus === "starting" && !server && !(await serverUp()))) {
    await ensureServer();
    changed = true;
  }

  const adbBin = await adbPath();
  const nowMissing = !adbBin;
  if (nowMissing !== adbMissing) {
    adbMissing = nowMissing;
    changed = true;
    if (adbMissing) {
      notify("未检测到 adb：手机无法通过 USB 连接。请安装 Android Platform Tools（菜单内可复制安装命令）。");
    } else {
      event(`已找到 adb：${adbBin}`);
    }
  }

  if (adbMissing) {
    if (devState !== "absent" || device !== null) {
      devState = "absent";
      device = null;
      adbReady = false;
      changed = true;
    }
  } else {
    const dev = await deviceState();
    if (dev !== devState) {
      changed = true;
      if (dev === "unauthorized") notify("手机已连接但未授权——请在手机弹窗中允许 USB 调试。");
      if (dev === "absent" && devState === "ok") notify("手机已断开。");
    }
    devState = dev;
    if (dev === "ok") {
      const devices = await listDevices();
      const current = devices[0] ?? null;
      if (current?.serial !== device?.serial) {
        device = current;
        changed = true;
        if (current) notify(`手机已连接：${current.model}（${current.serial}）`);
      }
      adbReady = await ensureReverse(PORT);
      if (adbReady && !changed) {
        // 通道静默重建成功，不打扰
      } else if (adbReady) {
        event("连接就绪：手机 → adb reverse → 电脑服务");
      }
    } else {
      device = null;
      adbReady = false;
    }
  }

  if (cfg.provider === "mock" && serverStatus !== "reused") {
    aiStatus = "na";
  } else {
    const up = await checkAiBackend();
    const next: AiStatus = up ? "ok" : "down";
    if (next !== aiStatus) {
      changed = true;
      if (next === "down") {
        notify(`AI 后端不可达（${aiBackendEndpoint()}）——手机端将自动改走设置的远程 API。`);
      } else if (aiStatus !== "na" || serverStatus === "reused") {
        event(`AI 后端已连接：${aiBackendEndpoint()}`);
      }
      aiStatus = next;
    }
  }

  if (changed) rebuildMenu();
}

async function main(): Promise<void> {
  // 状态栏应用：隐藏 Dock 图标（打包后另由 LSUIElement 保证）
  app.dock?.hide();
  await app.whenReady();

  // 数据目录独立于 CLI 的 desktop/data，避免打包后往只读位置写入
  pairing = new PairingManager(app.getPath("userData"));
  event(`MsgRepo 托盘启动（数据目录 ${app.getPath("userData")}）`);

  tray = new Tray(trayIcon());
  rebuildMenu();

  await ensureServer();
  rebuildMenu();

  setInterval(() => {
    tick().catch((e) => log(`看护异常：${String(e)}`));
  }, 5000);
  await tick().catch((e) => log(`看护异常：${String(e)}`));
  rebuildMenu();

  app.on("before-quit", () => {
    if (server) {
      log("停止内嵌服务…");
      server.close();
      server = null;
    }
  });
}

// 无窗口应用，保持常驻
app.on("window-all-closed", () => {});

main().catch((err) => {
  console.error(err);
  app.quit();
});

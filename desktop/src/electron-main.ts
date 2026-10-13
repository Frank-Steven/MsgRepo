import { app, Tray, Menu, nativeImage, clipboard, shell } from "electron";
import type { Server } from "node:http";
import path from "node:path";
import { loadConfig } from "./config.js";
import { DESKTOP_ROOT } from "./registry.js";
import { PairingManager } from "./auth.js";
import { Store } from "./store.js";
import { createServer } from "./server.js";
import { createProvider } from "./ai/factory.js";
import { deviceState, ensureReverse, type DeviceState } from "./adb.js";

/**
 * macOS 状态栏托盘主进程（设计 §11）：无 Dock 图标、无主窗口。
 * 职责 = 内嵌 HTTP 服务（复用 server.ts，端口被占用时复用已在运行的实例）
 *       + adb reverse 看护（复用 adb.ts，无设备时静默重试）
 *       + 托盘菜单（状态/配对码/仪表盘/开机自启/退出）。
 */

const cfg = loadConfig();
const PORT = cfg.port;
const HOST = cfg.host;
const BASE_URL = `http://${HOST}:${PORT}`;

// 固定应用名，保证 userData 目录稳定为 ~/Library/Application Support/MsgRepo
app.setName("MsgRepo");

let server: Server | null = null;
let tray: Tray | null = null;
let pairing: PairingManager;
let providerName = "";
let providerModel = "";
let lastDevice: DeviceState | "" = "";
let adbReady = false;

function log(msg: string): void {
  console.log(`[${new Date().toLocaleTimeString("zh-CN", { hour12: false })}] ${msg}`);
}

/** 已有服务在跑（比如 CLI 起的）就直接复用，避免端口冲突；否则进程内启动。 */
async function ensureServer(): Promise<void> {
  try {
    const res = await fetch(`${BASE_URL}/v1/health`, { signal: AbortSignal.timeout(3000) });
    if (res.ok) {
      const health = (await res.json()) as { provider?: string };
      providerName = health.provider ?? "";
      if (!server) log(`检测到服务已在运行：${BASE_URL}（provider=${providerName}，复用，不再拉起）`);
      return;
    }
  } catch {
    // 服务未运行，往下走进程内启动
  }
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
  await new Promise<void>((resolve, reject) => {
    server!.once("error", reject);
    server!.listen(PORT, HOST, () => {
      log(`服务已启动: ${BASE_URL}（provider=${providerName}${providerModel ? ` (${providerModel})` : ""}）`);
      resolve();
    });
  });
}

function trayIcon() {
  const image = nativeImage.createFromPath(path.join(DESKTOP_ROOT, "assets", "iconTemplate.png"));
  image.setTemplateImage(true);
  return image;
}

function deviceLabel(dev: DeviceState | ""): string {
  switch (dev) {
    case "ok":
      return adbReady ? "已连接（通道就绪）" : "已连接（通道重建中…）";
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
  const menu = Menu.buildFromTemplate([
    { label: "MsgRepo", enabled: false },
    { type: "separator" },
    { label: `服务：运行中  ${BASE_URL}`, enabled: false },
    { label: `AI：${providerName}${providerModel ? `（${providerModel}）` : ""}`, enabled: false },
    { label: `手机：${deviceLabel(lastDevice)}`, enabled: false },
    { type: "separator" },
    { label: `配对码：${token.slice(0, 8)}…`, enabled: false },
    {
      label: "复制配对码",
      click: () => {
        clipboard.writeText(pairing.token);
        log("配对码已复制到剪贴板");
      },
    },
    {
      label: "重置配对码",
      click: () => {
        pairing.reset();
        rebuildMenu();
        log("配对码已重置，手机端需重新配对（401 时会自动重配）");
      },
    },
    { type: "separator" },
    { label: "打开仪表盘", click: () => void shell.openExternal(`${BASE_URL}/dashboard`) },
    {
      label: "开机自启",
      type: "checkbox",
      checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => {
        app.setLoginItemSettings({ openAtLogin: item.checked });
        log(`开机自启已${item.checked ? "开启" : "关闭"}`);
      },
    },
    { type: "separator" },
    { label: "退出", click: () => app.quit() },
  ]);
  tray.setContextMenu(menu);
  tray.setToolTip(`MsgRepo · ${deviceLabel(lastDevice)}`);
}

/** adb 看护：每 5 秒一轮；设备插拔/授权变化只在状态切换时打日志，无设备静默重试。 */
async function adbTick(): Promise<void> {
  const dev = await deviceState();
  if (dev !== lastDevice) {
    if (dev === "unauthorized") log("手机已连接但未授权——请在手机弹窗中允许 USB 调试。");
    if (dev === "ok") log("检测到手机，确保 adb reverse 通道…");
    if (dev === "absent" && lastDevice !== "") log("手机已断开。");
  }
  if (dev === "ok") {
    adbReady = await ensureReverse(PORT);
    if (adbReady && lastDevice !== "ok") log("连接就绪：手机 → adb reverse → 电脑服务");
  } else {
    adbReady = false;
  }
  if (dev !== lastDevice || dev === "ok") {
    lastDevice = dev;
    rebuildMenu();
  } else {
    lastDevice = dev;
  }
}

async function main(): Promise<void> {
  // 状态栏应用：隐藏 Dock 图标（打包后另由 LSUIElement 保证）
  app.dock?.hide();
  await app.whenReady();

  // 数据目录独立于 CLI 的 desktop/data，避免打包后往只读位置写入
  pairing = new PairingManager(app.getPath("userData"));
  log(`MsgRepo 托盘启动（数据目录 ${app.getPath("userData")}）`);

  await ensureServer();

  tray = new Tray(trayIcon());
  rebuildMenu();

  setInterval(() => {
    adbTick().catch((e) => log(`看护异常：${String(e)}`));
  }, 5000);
  await adbTick().catch((e) => log(`看护异常：${String(e)}`));

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

/**
 * 生成托盘/应用图标（无美术资源，程序化绘制）：
 *   assets/iconTemplate.png    16x16  macOS 状态栏 template 图（黑色剪影 + 透明背景）
 *   assets/iconTemplate@2x.png 32x32  Retina 版本
 *   assets/icon.png            512x512 electron-builder 应用图标（自动转 icns）
 * 图形：对话气泡剪影（圆角矩形 + 左下小尾巴）。
 * 用法：node scripts/make-icons.mjs
 */
import { deflateSync } from "node:zlib";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ASSETS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "assets");

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, "ascii");
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

/** 8-bit RGBA PNG 编码（无外部依赖）。 */
function encodePng(width, height, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type RGBA
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

function inRoundRect(x, y, x0, y0, x1, y1, r) {
  if (x >= x0 + r && x <= x1 - r && y >= y0 && y <= y1) return true;
  if (y >= y0 + r && y <= y1 - r && x >= x0 && x <= x1) return true;
  for (const [cx, cy] of [
    [x0 + r, y0 + r],
    [x1 - r, y0 + r],
    [x0 + r, y1 - r],
    [x1 - r, y1 - r],
  ]) {
    if ((x - cx) ** 2 + (y - cy) ** 2 <= r * r) return true;
  }
  return false;
}

function inTriangle(px, py, ax, ay, bx, by, cx, cy) {
  const s1 = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
  const s2 = (cx - bx) * (py - by) - (cy - by) * (px - bx);
  const s3 = (ax - cx) * (py - cy) - (ay - cy) * (px - cx);
  return (s1 >= 0 && s2 >= 0 && s3 >= 0) || (s1 <= 0 && s2 <= 0 && s3 <= 0);
}

/** 气泡剪影：归一化坐标下判断点是否在图形内。 */
function inBubble(x, y) {
  return (
    inRoundRect(x, y, 0.08, 0.1, 0.92, 0.72, 0.2) ||
    inTriangle(x, y, 0.26, 0.7, 0.26, 0.94, 0.52, 0.7)
  );
}

function render(size) {
  const rgba = Buffer.alloc(size * size * 4);
  for (let py = 0; py < size; py++) {
    for (let px = 0; px < size; px++) {
      const x = (px + 0.5) / size;
      const y = (py + 0.5) / size;
      if (inBubble(x, y)) {
        const i = (py * size + px) * 4;
        rgba[i] = 0;
        rgba[i + 1] = 0;
        rgba[i + 2] = 0;
        rgba[i + 3] = 255;
      }
    }
  }
  return encodePng(size, size, rgba);
}

mkdirSync(ASSETS, { recursive: true });
writeFileSync(path.join(ASSETS, "iconTemplate.png"), render(16));
writeFileSync(path.join(ASSETS, "iconTemplate@2x.png"), render(32));
writeFileSync(path.join(ASSETS, "icon.png"), render(512));
console.log(`图标已生成到 ${ASSETS}`);

#!/usr/bin/env node
/** 生成 macOS 应用图标 build/icon.png (1024x1024) —— 纯 Node 实现, 无第三方依赖 */
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const SIZE = 1024;

// ---- 最小 PNG 编码器 ----
function crc32(buf) {
  let c, table = crc32.table;
  if (!table) {
    table = crc32.table = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[n] = c;
    }
  }
  c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = table[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const t = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([t, data])), 0);
  return Buffer.concat([len, t, data, crc]);
}

function encodePNG(width, height, rgba) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 6;  // color type RGBA
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (width * 4 + 1)] = 0; // filter none
    rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  }
  const idat = zlib.deflateSync(raw, { level: 9 });
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))]);
}

// ---- 绘制: 圆角渐变背景 + 白色 "M" 圆点阵 ----
function lerp(a, b, t) { return a + (b - a) * t; }
function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }

// 圆角矩形 SDF
function roundRectSDF(px, py, cx, cy, halfW, halfH, r) {
  const qx = Math.abs(px - cx) - (halfW - r);
  const qy = Math.abs(py - cy) - (halfH - r);
  const ax = Math.max(qx, 0), ay = Math.max(qy, 0);
  return Math.hypot(ax, ay) + Math.min(Math.max(qx, qy), 0) - r;
}

// 紫色渐变 (MoCode 品牌色)
const C0 = [96, 88, 255];   // #6058ff 顶部
const C1 = [56, 150, 255];  // #3896ff 底部

const icon = Buffer.alloc(SIZE * SIZE * 4);

const halfW = SIZE * 0.46, halfH = SIZE * 0.46, radius = SIZE * 0.22;
const cx = SIZE / 2, cy = SIZE / 2;

// "M" 字形 —— 用两竖一斜折线的球体近似
const balls = [];
const bars = [];
// 左竖
for (let i = 0; i < 5; i++) balls.push([cx - SIZE * 0.24, cy + SIZE * 0.18 - i * SIZE * 0.085]);
// 右竖
for (let i = 0; i < 5; i++) balls.push([cx + SIZE * 0.24, cy + SIZE * 0.18 - i * SIZE * 0.085]);
// 中尖 V 折线
for (let i = 0; i < 6; i++) balls.push([cx - SIZE * 0.24 + i * SIZE * 0.096, cy + SIZE * 0.18 - i * SIZE * 0.085]);
// 中尖 V 右侧
for (let i = 0; i < 6; i++) balls.push([cx + SIZE * 0.24 - i * SIZE * 0.096, cy + SIZE * 0.18 - i * SIZE * 0.085]);

const ballR = SIZE * 0.048;

for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    const px = x + 0.5, py = y + 0.5;
    const sdf = roundRectSDF(px, py, cx, cy, halfW, halfH, radius);
    if (sdf > 0) {
      // 背景外 -> 透明
      icon[(y * SIZE + x) * 4 + 3] = 0;
      continue;
    }
    // 抗锯齿边界
    const alphaBg = clamp(0.5 - sdf, 0, 1);
    const t = (py - (cy - halfH)) / (2 * halfH);
    const r = lerp(C0[0], C1[0], t);
    const g = lerp(C0[1], C1[1], t);
    const b = lerp(C0[2], C1[2], t);
    let fr = r, fg = g, fb = b, fa = alphaBg;

    // 白色 "M" 点
    for (const [bx, by] of balls) {
      const d = Math.hypot(px - bx, py - by);
      if (d < ballR) {
        const a = clamp(ballR - d, 0, 1.5) / 1.5 * alphaBg;
        fr = lerp(fr, 255, a);
        fg = lerp(fg, 255, a);
        fb = lerp(fb, 255, a);
        fa = Math.max(fa, a);
        break;
      }
    }
    const off = (y * SIZE + x) * 4;
    icon[off] = Math.round(fr);
    icon[off + 1] = Math.round(fg);
    icon[off + 2] = Math.round(fb);
    icon[off + 3] = Math.round(fa * 255);
  }
}

const outDir = path.resolve(__dirname, '..', 'build');
fs.mkdirSync(outDir, { recursive: true });
const png = encodePNG(SIZE, SIZE, icon);
const outPng = path.join(outDir, 'icon.png');
fs.writeFileSync(outPng, png);
console.log('已生成:', outPng, png.length, 'bytes');

// 同时生成小尺寸 tray 图标 (32x32)
const traySize = 32;
const trayPng = Buffer.alloc(traySize * traySize * 4);
for (let y = 0; y < traySize; y++) {
  for (let x = 0; x < traySize; x++) {
    // 取样自大图中心区域(近似缩略)
    const sx = Math.floor(x / traySize * SIZE + SIZE * 0.25) * SIZE * 4;
    const sy = y / traySize * SIZE;
    const si = (Math.floor(sy) * SIZE + Math.floor(x / traySize * SIZE)) * 4;
    trayPng[(y * traySize + x) * 4] = icon[si];
    trayPng[(y * traySize + x) * 4 + 1] = icon[si + 1];
    trayPng[(y * traySize + x) * 4 + 2] = icon[si + 2];
    trayPng[(y * traySize + x) * 4 + 3] = icon[si + 3];
  }
}
const outTray = path.join(outDir, 'tray.png');
fs.writeFileSync(outTray, encodePNG(traySize, traySize, trayPng));
console.log('已生成:', outTray);

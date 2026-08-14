#!/usr/bin/env node
/**
 * 准备 macOS 打包所需的运行时:
 *   1. 把后端 app_data(dist_cpp/app_data)复制到 runtime/app_data
 *   2. 下载 macOS Python 运行时(python-build-standalone)到 runtime/python-macos
 *
 * 用法: node scripts/setup_runtime.js [--no-python]
 */
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const https = require('https');

const ROOT = path.resolve(__dirname, '..');
const SRC_APP_DATA = path.resolve(__dirname, '../..', 'dist_cpp', 'app_data');
const DST_APP_DATA = path.join(ROOT, 'runtime', 'app_data');
const DST_PYTHON = path.join(ROOT, 'runtime', 'python-macos');

// 后端入口脚本(mocode_run.py)位于 packaging/cpp/, 需一并打进 app_data 根目录,
// 供 main.js 以 appData/mocode_run.py 启动。
const SRC_MOCODE_RUN = path.resolve(__dirname, '../..', 'cpp', 'mocode_run.py');

// python-build-standalone 版本(可改)
// 注意: tag 是纯日期(如 20240415), 版本号只出现在资产文件名里, 不要拼进 tag。
const PY_VERSION = '3.11.9';
const PY_TAG = '20240415';
const URLS = {
  x64: `https://github.com/astral-sh/python-build-standalone/releases/download/${PY_TAG}/cpython-${PY_VERSION}+${PY_TAG}-x86_64-apple-darwin-install_only.tar.gz`,
  arm64: `https://github.com/astral-sh/python-build-standalone/releases/download/${PY_TAG}/cpython-${PY_VERSION}+${PY_TAG}-aarch64-apple-darwin-install_only.tar.gz`,
};

function copyDir(src, dst, ignore = ['__pycache__', '.git', '*.pyc']) {
  if (!fs.existsSync(src)) throw new Error(`源不存在: ${src}`);
  fs.mkdirSync(dst, { recursive: true });
  const entries = fs.readdirSync(src, { withFileTypes: true });
  for (const e of entries) {
    if (ignore.includes(e.name)) continue;
    const s = path.join(src, e.name);
    const d = path.join(dst, e.name);
    if (e.isDirectory()) copyDir(s, d, ignore);
    else fs.copyFileSync(s, d);
  }
}

function download(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);
    let settled = false;
    const fail = (e) => { if (!settled) { settled = true; file.destroy(); reject(e); } };
    const done = () => { if (!settled) { settled = true; file.close(resolve); } };
    https.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        // 重定向: 丢弃本响应体, 关闭本次流后跳到新地址(避免对同一 dest 开两个写流)
        res.resume();
        const next = res.headers.location;
        file.close(() => {
          console.log(`重定向 -> ${next.slice(0, 80)}...`);
          download(next, dest).then(resolve, reject);
        });
        return;
      }
      if (res.statusCode !== 200) {
        res.resume();
        fail(new Error(`HTTP ${res.statusCode} for ${url}`));
        return;
      }
      res.pipe(file);
      file.on('finish', done);
    }).on('error', fail);
  });
}

async function main() {
  const args = process.argv.slice(2);
  const skipPython = args.includes('--no-python');

  console.log('== 1) 复制后端 app_data ==');
  // 幂等: 若 runtime/app_data 已就绪(含入口+转译器, 例如 Windows 侧已预置), 则跳过复制。
  const readyEntry = path.join(DST_APP_DATA, 'mocode_run.py');
  const readyTp = path.join(DST_APP_DATA, 'channel', 'web', 'mocode', 'mo_transpiler.py');
  if (fs.existsSync(readyEntry) && fs.existsSync(readyTp)) {
    console.log(`  ✓ runtime/app_data 已就绪, 跳过复制(${DST_APP_DATA})`);
    return;
  }
  try {
    copyDir(SRC_APP_DATA, DST_APP_DATA);
    if (fs.existsSync(SRC_MOCODE_RUN)) {
      fs.copyFileSync(SRC_MOCODE_RUN, path.join(DST_APP_DATA, 'mocode_run.py'));
      console.log('  ✓ 已打入后端入口 mocode_run.py');
    } else {
      console.warn('  ⚠ 未找到 packaging/cpp/mocode_run.py');
    }
    console.log(`  → ${DST_APP_DATA}`);
    const web = path.join(DST_APP_DATA, 'channel', 'web');
    if (!fs.existsSync(path.join(web, 'mocode', 'mo_transpiler.py'))) {
      console.warn('  ⚠ 未找到 channel/web/mocode/mo_transpiler.py，确认源 app_data 结构正确');
    } else {
      console.log('  ✓ 包含 channel/web/mocode(mo_transpiler.py)');
    }
  } catch (e) {
    console.error('复制 app_data 失败:', e.message);
    process.exit(1);
  }

  if (skipPython) {
    console.log('  (跳过 Python 下载 --no-python)');
    return;
  }

  console.log('== 2) 下载 macOS Python 运行时 ==');
  process.env.PYTHONUNBUFFERED = '1';
  for (const [arch, url] of Object.entries(URLS)) {
    const outDir = path.join(DST_PYTHON, arch);
    const marker = path.join(outDir, 'python', 'bin', 'python3');
    if (fs.existsSync(marker)) {
      console.log(`  ✓ ${arch} 已存在, 跳过下载(${outDir})`);
      continue; // 幂等: 已在 Windows 侧预置, Mac 上无需重下
    }
    const tmp = path.join(ROOT, 'runtime', `python-${arch}.tar.gz`);
    fs.mkdirSync(path.dirname(tmp), { recursive: true });
    try {
      await download(url, tmp);
      fs.mkdirSync(outDir, { recursive: true });
      execSync(`tar -xzf "${tmp}" -C "${outDir}" --strip-components=0`, { stdio: 'inherit' });
      fs.unlinkSync(tmp);
      console.log(`  ✓ ${arch} -> ${outDir}`);
    } catch (e) {
      console.error(`  ✗ ${arch} 下载失败: ${e.message}`);
      console.error('    请手动下载并解压到 runtime/python-macos/<arch>/ , 或稍后重试。');
    }
  }
}

main();

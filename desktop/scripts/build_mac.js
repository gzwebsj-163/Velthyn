#!/usr/bin/env node
/**
 * 一键构建 macOS DMG:
 *   1. 生成图标 build/icon.png + tray.png
 *   2. 准备运行时 runtime/ (app_data + macOS Python)
 *   3. electron-builder 构建 dmg (arm64 + x64)
 *
 * 用法:
 *   node scripts/build_mac.js            # 生成图标+运行时 + 构建 dmg
 *   node scripts/build_mac.js --dir      # 只生成 .app 目录(不打包 dmg)
 *   node scripts/build_mac.js --no-python # 跳过 Python 下载(若已缓存)
 */
const { spawnSync } = require('child_process');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');

function run(cmd, args, label) {
  console.log(`\n== ${label} ==\n> ${cmd} ${args.join(' ')}`);
  const r = spawnSync(cmd, args, { cwd: ROOT, stdio: 'inherit', shell: true });
  if (r.status !== 0) {
    console.error(`[构建失败] ${label} (exit ${r.status})`);
    process.exit(r.status || 1);
  }
}

const args = process.argv.slice(2);
const dirOnly = args.includes('--dir');
const noPython = args.includes('--no-python');

run('node', ['scripts/gen_icon.js'], '生成应用图标');
run('node', ['scripts/setup_runtime.js', ...(noPython ? ['--no-python'] : [])], '准备运行时(app_data + macOS Python)');

if (dirOnly) {
  run('npx', ['electron-builder', '--mac', 'dir'], '构建 .app (目录)');
} else {
  run('npx', ['electron-builder', '--mac', 'dmg'], '构建 DMG');
}

console.log('\n完成! 产出见 release/ 目录。');
console.log('注意: Windows 上交叉打包未签名(identity=null), 首次在 Mac 打开需右键->打开, 或在 System Settings 放行。');

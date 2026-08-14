// MoCode Desktop — Electron 主进程 (macOS)
// 功能: 启动内置 Python 后端(端口 9899) + 加载 Web 前端, 与 Windows 版 MoCodeDesktop 一致。
const { app, BrowserWindow, Tray, Menu, dialog, nativeImage } = require('electron');
const { spawn, execSync, spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const BACKEND_URL = 'http://localhost:9899/chat';
const HEALTH_URL = 'http://localhost:9899/api/health';
const BACKEND_PORT = 9899;

// 单实例锁
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
}

let mainWindow = null;
let tray = null;
let backendProc = null;
let quitting = false;

// 定位随应用打包的运行时资源 (Contents/Resources/)
function resourcePath(rel) {
  const p = path.join(process.resourcesPath, rel);
  return p;
}

// 找到打包进来的 macOS Python 解释器
function findPython() {
  const roots = [resourcePath('python'), resourcePath('py'), resourcePath('python-macos')];
  const rels = [
    'bin/python3',
    'bin/python3.11',
    'bin/python',
    'python/bin/python3',
    'python/bin/python3.11',
    'Python.framework/Versions/3.11/bin/python3',
  ];
  // 1) 顶层相对路径
  for (const r of roots) {
    for (const rel of rels) {
      const c = path.join(r, rel);
      if (fs.existsSync(c)) return c;
    }
  }
  // 2) 递归查找架构子目录(x64/arm64 各自嵌套一层 python/)
  if (fs.existsSync(roots[0])) {
    // 优先匹配本机架构: Apple Silicon -> arm64, Intel -> x64
    const prefer = process.arch === 'arm64' ? 'arm64' : 'x64';
    const candidates = [prefer, prefer === 'arm64' ? 'x64' : 'arm64'];
    for (const a of candidates) {
      const c = path.join(roots[0], a, 'python', 'bin', 'python3');
      if (fs.existsSync(c)) return c;
    }
  }
  return null;
}

// app_data 后端资源目录
function findAppData() {
  // app_data 必须是包含 channel/web/mocode/mo_transpiler.py 的根
  const marker = path.join('channel', 'web', 'mocode', 'mo_transpiler.py');
  const d = resourcePath('app_data');
  if (fs.existsSync(path.join(d, 'channel'))) {
    return d;
  }
  // 回退: 若找不到 mo_transpiler, 尝试其父目录
  if (fs.existsSync(path.join(d, marker))) {
    return d;
  }
  return d;
}

// 拷贝后端到用户数据目录? 这里采用“直接运行只读资源”策略:
// app_data 内首次运行会转译 .mo -> .py, 但资源目录可能只读(macOS .app)。
// 故首次启动时同步到 userData, 保证可写。
function ensureWritableAppData(src) {
  const dst = path.join(app.getPath('userData'), 'app_data');
  if (!fs.existsSync(dst)) {
    try {
      fs.mkdirSync(path.dirname(dst), { recursive: true });
      copyRecursiveSync(src, dst);
    } catch (e) {
      // 复制失败则回退到只读源(若可写)
      console.error('copy app_data failed:', e);
      return src;
    }
  }
  return dst;
}

function copyRecursiveSync(src, dest) {
  if (!fs.existsSync(src)) return;
  if (fs.lstatSync(src).isDirectory()) {
    fs.mkdirSync(dest, { recursive: true });
    const entries = fs.readdirSync(src, { withFileTypes: true });
    for (const e of entries) {
      if (e.name === '__pycache__' || e.name === '.git') continue;
      copyRecursiveSync(path.join(src, e.name), path.join(dest, e.name));
    }
  } else {
    if (!fs.existsSync(dest) || fs.lstatSync(src).size !== fs.lstatSync(dest).size) {
      fs.copyFileSync(src, dest);
    }
  }
}

function killProcTree(child) {
  if (!child || child.pid == null) return;
  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch (e) {
    try { child.kill('SIGKILL'); } catch (e2) { /* ignore */ }
  }
}

// 检查后端的第三方依赖是否可用; 缺失则用内置 pip 自动安装(带首次运行提示)。
// 正常打包(Mac 上 build_macos.sh)已预装这些包, 这里作为兜底。
// 因 .app 内资源目录只读, 依赖一律装到 userData/pydeps 并通过 PYTHONPATH 注入。
function userDepsDir() {
  return path.join(app.getPath('userData'), 'pydeps');
}

async function ensurePythonDeps(python) {
  const target = userDepsDir();
  // 将用户依赖目录加入 PYTHONPATH 后进行探测(资源目录只读, 依赖装在 userData)
  const env = Object.assign({}, process.env, { PYTHONPATH: target });
  const missing = probeMissing(python, env);
  if (!missing || missing.length === 0) return;
  console.log('[deps] 检测到缺失依赖:', missing.join(', '));
  const ok = await new Promise((resolve) => {
    dialog.showMessageBox(mainWindow, {
      type: 'info',
      title: '首次运行准备',
      message: '正在安装后端运行所需组件(web.py, requests 等)，仅首次需要，请稍候(需联网)。',
      buttons: ['继续', '取消'],
      defaultId: 0,
      cancelId: 1,
    }).then(({ response }) => resolve(response === 0));
  });
  if (!ok) return;
  fs.mkdirSync(target, { recursive: true });
  for (const cmd of [
    [python, '-m', 'ensurepip', '--default-pip'],
    [python, '-m', 'pip', 'install', '--upgrade', '--target', target, 'web.py', 'certifi', 'requests', 'Pillow', 'regex', 'opencc-python-reimplemented', 'croniter'],
  ]) {
    try {
      const r = spawnSync(cmd[0], cmd.slice(1), { stdio: 'inherit', timeout: 900000 });
      if (r.status !== 0) console.warn('[deps] 安装步骤退出码非0:', r.status);
    } catch (e) {
      console.warn('[deps] 安装失败:', e.message);
    }
  }
  const stillMissing = probeMissing(python, env);
  if (stillMissing && stillMissing.length) {
    dialog.showMessageBox(mainWindow, { type: 'warning', title: '依赖不完整',
      message: '部分组件仍未就绪(' + stillMissing.join(', ') + ')。请确认网络可用后重启应用，或在 Mac 上运行 scripts/build_macos.sh 重新打包。' });
  }
}

function probeMissing(python, env) {
  const r = spawnSync(python, [
    '-c',
    'import importlib.util; mods=["web","requests","certifi","PIL","regex","opencc","croniter"]; print(",".join(m for m in mods if importlib.util.find_spec(m) is None))'
  ], { env: env || process.env });
  const out = (r.stdout || '').toString();
  return out.split(',').map(s => s.trim()).filter(Boolean);
}

// 启动后端
async function startBackend(python, appData) {
  // 后端入口: app_data 根下的 mocode_run.py (与 Windows 版一致)
  let script = path.join(appData, 'mocode_run.py');
  const alt = path.join(appData, 'launcher.py');
  if (!fs.existsSync(script) && fs.existsSync(alt)) {
    script = alt;
  }
  // macOS quick 判断: 若 script 不存在则提示
  if (!fs.existsSync(script)) {
    return new Promise((resolve) => {
      dialog.showMessageBox(mainWindow, {
        type: 'error',
        title: '后端缺失',
        message: `未找到后端入口:\n${script}\n请检查应用资源完整性。`,
      }).then(() => resolve(false));
    });
  }

  const env = Object.assign({}, process.env, {
    // 注意: 后端 mocode_run.py 读取的变量名是 "Mocode_APP_ROOT" (小写 ode), 不能拼错!
    Mocode_APP_ROOT: appData,
    COW_DESKTOP: '1',
  });
  // 注入首次运行自装依赖目录(资源目录只读 -> userData/pydeps)
  const deps = userDepsDir();
  if (fs.existsSync(deps)) {
    env.PYTHONPATH = [deps, env.PYTHONPATH].filter(Boolean).join(':');
  }
  delete env.GR_APP_ROOT;

  const args = [script];
  backendProc = spawn(python, args, {
    cwd: path.dirname(python),
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: true,
  });
  backendProc.stdout.on('data', (d) => console.log('[backend]', String(d).trim().slice(-600)));
  backendProc.stderr.on('data', (d) => console.error('[backend-err]', String(d).trim().slice(-600)));
  backendProc.on('exit', (code) => {
    console.log('[backend] exited', code);
    if (!quitting && mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(
        '<html><body style="background:#f3f4f6;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh">' +
        '<div style="text-align:center"><div style="font-size:22px;color:#c0392b">服务已退出</div>' +
        '<div style="margin-top:10px;color:#666">后端进程异常退出，请重新打开应用。</div></div></body></html>'));
    }
  });
  return waitForHealth();
}

async function waitForHealth(timeoutMs = 180000) {
  const start = Date.now();
  const url = 'http://localhost:9899/api/health';
  while (Date.now() - start < timeoutMs) {
    if (backendProc && backendProc.exitCode != null) return false;
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(2000) });
      if (res.ok) return true;
    } catch (e) { /* not ready */ }
    await new Promise((r) => setTimeout(r, 1000));
  }
  return false;
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 960,
    minHeight: 600,
    title: 'MoCode Desktop',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, 'preload.js'),
    },
  });
  mainWindow.on('minimize', (e) => {
    if (process.platform === 'darwin') {
      // macOS 最小化到 Dock, 不隐藏
    } else {
      e.preventDefault();
      mainWindow.hide();
    }
  });
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    // 新窗口一律在当前窗口内打开
    mainWindow.loadURL(url);
    return { action: 'deny' };
  });
  mainWindow.on('closed', () => { mainWindow = null; });
}

function setupTray() {
  let iconPath = path.join(__dirname, 'build', 'tray.png');
  let image = fs.existsSync(iconPath) ? nativeImage.createFromPath(iconPath) : nativeImage.createEmpty();
  tray = new Tray(image.isEmpty() ? nativeImage.createFromDataURL(
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAABGdBTUEAALGPC/xhBQAA'
  ) : image);
  tray.setToolTip('MoCode Desktop');
  const menu = Menu.buildFromTemplate([
    { label: '显示', click: () => { if (mainWindow) { mainWindow.show(); mainWindow.focus(); } } },
    { type: 'separator' },
    { label: '退出', click: () => { app.quit(); } },
  ]);
  tray.setContextMenu(menu);
}

app.whenReady().then(async () => {
  setupTray();
  createWindow();

  const python = findPython();
  const appData = findAppData();
  const writableData = ensureWritableAppData(appData);

  if (!python) {
    dialog.showMessageBox(mainWindow, {
      type: 'error',
      title: '缺少 Python 运行时',
      message: '未找到打包的 macOS Python 运行时，无法启动后端。请重新安装应用。',
    }).then(() => {
      // 仍然打开窗口, 显示记录错误
    });
  }

  if (python) {
    await ensurePythonDeps(python);
  }

  const ok = python && (await startBackend(python, writableData));
  if (ok && mainWindow) {
    mainWindow.loadURL(BACKEND_URL);
  } else if (mainWindow) {
    mainWindow.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(
      '<html><body style="background:#f3f4f6;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh">' +
      '<div style="text-align:center"><div style="font-size:22px;color:#c0392b">服务启动失败</div>' +
      '<div style="margin-top:10px;color:#666">后端未能在限时内就绪。请查看日志或重新安装。</div></div></body></html>'));
  }

  // 第二个实例唤起
  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.show();
      mainWindow.focus();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

app.on('before-quit', () => {
  quitting = true;
  if (backendProc) killProcTree(backendProc);
});

app.on('will-quit', () => {
  if (backendProc) killProcTree(backendProc);
});

app.on('activate', () => {
  if (mainWindow === null) createWindow();
});

#!/bin/bash
# ============================================================
# MoCode Desktop — macOS 构建脚本(必须在 macOS 上运行)
# 由于 Windows 无法交叉编译 macOS 原生二进制/签名/生成 dmg, 最终产出自此脚本产出。
# 前置: 已在本工程执行过 `npm install`
# 用法:
#   ./scripts/build_macos.sh            # 双架构(arm64+x64) + DMG
#   ARCHS=arm64 ./scripts/build_macos.sh # 仅 arm64
#   MODE=dir  ./scripts/build_macos.sh  # 只生成 .app, 不打包 dmg
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
export ELECTRON_SKIP_BINARY_DOWNLOAD=1

ARCHS="${ARCHS:-arm64 x64}"
MODE="${MODE:-dmg}"
DEPS_FILE="runtime_deps.txt"

echo "==> 1) 准备运行时(app_data + macOS Python)"
node scripts/setup_runtime.js 2>&1 || echo "(若已存在 Python 可忽略)"

echo "==> 2) 为各架构安装运行时依赖"
for arch in $ARCHS; do
  PYDIR="runtime/python-macos/$arch"
  # python-build-standalone 的 tar 顶层有一层 python/, 实际解释器在 $PYDIR/python/bin/python3
  PYROOT="$PYDIR/python"
  if [ ! -x "$PYROOT/bin/python3" ]; then
    echo "    [$arch] 跳过: 未找到 $PYROOT/bin/python3"
    continue
  fi
  PYVER=$(ls "$PYROOT/lib" 2>/dev/null | grep -E '^python3' | head -1 || echo python3.11)
  SITE_PKG="$PYROOT/lib/$PYVER/site-packages"
  mkdir -p "$SITE_PKG"
  # python-build-standalone 的 install_only 常缺 pip, 用 ensurepip; 失败则跳过
  "$PYROOT/bin/python3" -m ensurepip --default-pip 2>/dev/null || true
  echo "    [$arch] 安装依赖到 $SITE_PKG"
  "$PYROOT/bin/python3" -m pip install --upgrade pip 2>/dev/null || true
  "$PYROOT/bin/python3" -m pip install \
      --target "$SITE_PKG" \
      -r "$DEPS_FILE" \
      --upgrade --prefer-binary 2>&1 | tail -3 || echo "    (pip 失败, 依赖将走首次运行自动安装)"
done

echo "==> 3) 构建 Electron 产物"
if [ "$MODE" = "dir" ]; then
  npx electron-builder --mac dir
else
  # 由本机架构决定默认目标; 需两架构则用 universal 或分别 --x64/--arm64
  npx electron-builder --mac
fi

echo "==> 完成! 查看 release/ 目录"
echo "    · release/*.app       应用包"
echo "    · release/*.dmg       安装镜像(默认本机架构)"
echo "提示: 未签名则首次打开需 右键->打开 或在 系统设置->隐私与安全性 放行。"

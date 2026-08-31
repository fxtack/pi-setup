#!/usr/bin/env bash
# ============================================================
#  install-betterchromium.sh — 安装 BetterChromium（BetterWright 托管浏览器）
#
#  背景：betterwright 的 `setup` 从 GitHub Releases 直连下载浏览器 zip，
#  在国内直连仅 ~43KB/s（182MB 需 1 小时+ 且常中途断连卡死，15 分钟超时只下几 KB）。
#  本脚本优先走 gh-proxy.com 镜像（实测 24-33MB/s，5 秒完成），失败自动回退直连。
#
#  用法:
#    bash scripts/install-betterchromium.sh            # 幂等，已安装则跳过
#    bash scripts/install-betterchromium.sh --force    # 强制重新下载
#
#  可覆盖环境变量:
#    BETTERWRIGHT_CHROMIUM_VERSION   版本号（默认与 betterwright 1.11.0 源码 pin 一致）
#    BETTERWRIGHT_CHROMIUM_RELEASE_TAG  GitHub release tag（默认 betterchromium-<版本>-r3）
#    BETTERWRIGHT_DOWNLOAD_MIRROR    镜像前缀（默认 https://gh-proxy.com，设空则跳过镜像）
#    BETTERWRIGHT_HOME               BetterWright 数据根（默认 ~/.betterwright）
# ============================================================
set -euo pipefail

# ---- 参数 ----
FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  "") ;;
  *) echo "用法: bash $0 [--force]"; exit 1 ;;
esac

# ---- 版本与发布（默认值 = betterwright 1.11.0 dist/src/chromium-fork.js 的 pin）----
BW_VERSION="${BETTERWRIGHT_CHROMIUM_VERSION:-151.0.7922.108}"
RELEASE_TAG="${BETTERWRIGHT_CHROMIUM_RELEASE_TAG:-betterchromium-${BW_VERSION}-r3}"
MIRROR="${BETTERWRIGHT_DOWNLOAD_MIRROR:-https://gh-proxy.com}"
ROOT="${BETTERWRIGHT_HOME:-$HOME/.betterwright}/chromium"

# ---- 平台资产表 ----
# sha256 来源：betterwright dist/src/chromium-fork.js 的 CHROMIUM_FORK_ASSETS
# 更新 betterwright 后若版本漂移，需同步更新下方版本号与 sha256（或设置环境变量覆盖）
case "$(uname -s):$(uname -m)" in
  Darwin:arm64)
    ASSET="betterchromium-mac-arm64.zip"
    SHA256="22484b810c601697afd7d0a82f39ced7f24ac7d8a2b01e52c5a61e9a6096ec67"
    LAYOUT="mac-arm64/BetterChromium.app/Contents/MacOS/BetterChromium"
    EXTRACT="ditto"          # macOS: ditto 保留 app bundle 元数据
    ;;
  Linux:x86_64)
    ASSET="betterchromium-linux-x64.zip"
    SHA256="3eabe54aae9d8bde34170a6930df21932325be4570baf9d45431baad6cd03d98"
    LAYOUT="linux-x64/betterchromium"
    EXTRACT="unzip"
    ;;
  MINGW*|MSYS*|CYGWIN*:x86_64)
    ASSET="betterchromium-win-x64.zip"
    SHA256="03d8abb5d6064bbd808cf52c2a327692502c4ca6c565b2e1cdb639200c52dccb"
    LAYOUT="win-x64/betterchromium.exe"
    EXTRACT="unzip"
    ;;
  *)
    echo "!! 平台 $(uname -s)-$(uname -m) 无公开 BetterChromium 产物，跳过"
    echo "   （可改用 provider 选项接入自备浏览器，见 betterwright docs/browser-providers.md）"
    exit 0
    ;;
esac

BINARY="$ROOT/$LAYOUT"
URL="https://github.com/BetterWright/betterwright/releases/download/${RELEASE_TAG}/${ASSET}"
SHA_CMD="shasum -a 256"
command -v shasum >/dev/null 2>&1 || SHA_CMD="sha256sum"

# ---- 幂等：已安装且未强制则跳过 ----
if [ $FORCE -eq 0 ] && [ -x "$BINARY" ] && [ -s "$BINARY" ]; then
  echo "✅ BetterChromium 已安装: $BINARY"
  echo "   （--force 可强制重新下载）"
  exit 0
fi

echo "==> 下载 BetterChromium ${BW_VERSION} (${ASSET}, ~180MB)"
echo "    release: ${RELEASE_TAG}"

# ---- 下载：镜像优先（国内快），失败自动回退直连 ----
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/bw-chromium-XXXXXX")"
ZIP="$TMPDIR/$ASSET"
ok=0
for src in "${MIRROR:+${MIRROR%/}/$URL}" "$URL"; do
  [ -n "$src" ] || continue
  echo "  - 尝试: $src"
  if curl -fL --connect-timeout 10 --max-time 900 -o "$ZIP" "$src"; then
    ok=1
    break
  fi
  echo "    ✗ 失败，换下一个源"
done
if [ $ok -ne 1 ]; then
  rm -rf "$TMPDIR"
  echo "!! 所有下载源均失败。检查网络，或设置 BETTERWRIGHT_DOWNLOAD_MIRROR 换镜像" >&2
  exit 1
fi
echo "    ✓ 下载完成 ($(du -h "$ZIP" | cut -f1))"

# ---- SHA-256 校验（防镜像投毒/损坏）----
ACTUAL="$($SHA_CMD "$ZIP" | awk '{print $1}')"
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "!! SHA-256 不匹配: 期望 $SHA256，实际 $ACTUAL" >&2
  rm -rf "$TMPDIR"
  exit 1
fi
echo "    ✓ SHA-256 校验通过 ($ACTUAL)"

# ---- 解压（先清掉旧平台目录，避免新旧文件混存）----
mkdir -p "$ROOT"
PLATFORM_DIR="$ROOT/$(dirname "$LAYOUT" | cut -d/ -f1)"
rm -rf "$PLATFORM_DIR"
case "$EXTRACT" in
  ditto) ditto -x -k "$ZIP" "$ROOT" ;;
  unzip) unzip -oq "$ZIP" -d "$ROOT" ;;
esac
rm -rf "$TMPDIR"

if [ ! -x "$BINARY" ] || [ ! -s "$BINARY" ]; then
  echo "!! 解压成功但未找到可执行文件: $BINARY（release zip 布局可能不匹配）" >&2
  exit 1
fi
chmod +x "$BINARY" 2>/dev/null || true
echo "✅ BetterChromium 已安装: $BINARY"

# ---- 可选：用 betterwright CLI 验证（能找到才跑，找不到只提示）----
BW_CLI=""
for c in \
  "$HOME/.pi/agent/npm/node_modules/betterwright/dist/bin/betterwright.js" \
  "$(npm root -g 2>/dev/null)/betterwright/dist/bin/betterwright.js"; do
  [ -f "$c" ] && BW_CLI="$c" && break
done
if [ -n "$BW_CLI" ]; then
  echo "==> betterwright doctor 验证"
  node "$BW_CLI" doctor 2>&1 | grep -E "BetterChromium|chromium-fork" || true
else
  echo "==> 未找到 betterwright CLI（pi 扩展或全局安装其一即可），跳过 doctor 验证"
fi

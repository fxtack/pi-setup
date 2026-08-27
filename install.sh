#!/usr/bin/env bash
# ============================================================
#  Pi 环境一键迁移脚本
#  安装所有插件/扩展，恢复全部配置与源码 patch
#  用法: bash install.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$SCRIPT_DIR/configs"
PATCHES="$SCRIPT_DIR/patches"
AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
NPM_DIR="$AGENT_DIR/npm/node_modules"
CONFIG_MCP_DIR="$HOME/.config/mcp"

# powerline-footer 版本被 patch 锁定，改版本前务必验证 patches/powerline.patch
POWERLINE_VERSION="0.16.0"

# 校验当前目录必须是 setup 仓库根（而不是被 clone 成 setup/setup 的子目录）
if [ ! -f "$CFG/powerline-theme.json" ]; then
  echo "!! 未找到配置资产。本脚本须从迁移包根目录运行: bash install.sh"
  exit 1
fi

echo "==> [1/6] 安装 pi 包（幂等，重复安装无害）"
for pkg in \
  "npm:pi-lmstudio" \
  "npm:pi-mcp-adapter" \
  "npm:@houndmcp/hound-mcp-pi" \
  "npm:pi-subagents" \
  "npm:@ff-labs/pi-fff" \
  "npm:pi-hermes-memory" \
  "npm:@gotgenes/pi-permission-system" \
  "npm:pi-powerline-footer@$POWERLINE_VERSION" \
  "npm:@juicesharp/rpiv-todo"; do
  echo "  - $pkg"
  pi install "$pkg" >/dev/null 2>&1 || { echo "  !! 安装失败: $pkg"; exit 1; }
done

echo "==> [2/6] 合并 powerline 配置到 settings.json"
python3 - "$AGENT_DIR/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
powerline = {
    "preset": "ascii",
    "welcome": False,
    "layout": {
        "left": ["context_pct", "token_in", "cache_read", "token_total",
                 "cost", "cache_write", "path", "git"],
        "right": ["model"],
    },
    "separator": "pipe",
}
with open(path) as f:
    data = json.load(f)
data["powerline"] = powerline
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print("  settings.json powerline 已写入")
PY

echo "==> [3/6] 复制配置文件"
mkdir -p "$AGENT_DIR/extensions/powerline-footer" \
         "$AGENT_DIR/extensions/pi-permission-system" \
         "$CONFIG_MCP_DIR"
cp "$CFG/powerline-theme.json" "$AGENT_DIR/extensions/powerline-footer/theme.json"
cp "$CFG/permission-config.json" "$AGENT_DIR/extensions/pi-permission-system/config.json"
cp "$CFG/mcp.json" "$CONFIG_MCP_DIR/mcp.json"
echo "  theme.json / permission config / mcp.json 已复制"

echo "==> [4/6] 环境变量（~/.zshenv，幂等）"
if ! grep -q "POWERLINE_NERD_FONTS=0" "$HOME/.zshenv" 2>/dev/null; then
  echo 'export POWERLINE_NERD_FONTS=0' >> "$HOME/.zshenv"
  echo "  已写入 ~/.zshenv"
else
  echo "  已存在，跳过"
fi
# hound 需要 ~/.pi/agent/bin 在 PATH（若已存在则跳过）
if [ -x "$HOME/.pi/agent/bin/hound" ] && ! echo "$PATH" | grep -q "$HOME/.pi/agent/bin"; then
  echo 'export PATH="$HOME/.pi/agent/bin:$PATH"' >> "$HOME/.zshenv"
  echo "  已把 ~/.pi/agent/bin 加入 PATH"
fi

echo "==> [5/6] 应用 powerline-footer 源码 patch（版本 $POWERLINE_VERSION）"
PFDIR="$NPM_DIR/pi-powerline-footer"
if [ ! -d "$PFDIR" ]; then
  echo "  !! 未找到 $PFDIR，无法应用 patch（请先重跑本脚本）"
  exit 1
fi

# 校验安装版本与 patch 锁定的版本一致，避免版本漂移导致 patch 失效
INSTALLED_VERSION="$(node -e "console.log(require('$PFDIR/package.json').version)" 2>/dev/null || echo unknown)"
if [ "$INSTALLED_VERSION" != "$POWERLINE_VERSION" ]; then
  echo "  !! powerline-footer 版本不匹配: 已装 $INSTALLED_VERSION，patch 针对 $POWERLINE_VERSION。"
  echo "  请手动安装 $POWERLINE_VERSION 后再重跑: pi install npm:pi-powerline-footer@$POWERLINE_VERSION"
  exit 1
fi

if grep -q 'minimal: "minimal"' "$PFDIR/icons.ts" 2>/dev/null; then
  echo "  patch 已应用过，跳过"
else
  if (cd "$PFDIR" && patch -p1 --dry-run < "$PATCHES/powerline.patch" >/dev/null 2>&1); then
    (cd "$PFDIR" && patch -p1 < "$PATCHES/powerline.patch" >/dev/null)
    echo "  patch 已应用"
  else
    echo "  !! patch dry-run 失败：源码与 patches/powerline.patch 期望的不一致。"
    echo "  请在干净的 0.16.0 安装上应用此 patch，或重新生成 patch。"
    exit 1
  fi
fi

echo "==> [6/6] 环境检查"
which pi >/dev/null 2>&1 || { echo "  !! 未找到 pi，请先安装 pi coding agent"; exit 1; }
if ! which hound >/dev/null 2>&1; then
  echo "  !! 未找到 hound（web 搜索工具）。安装: pip install hound-mcp[all]"
fi
if ! ls "$HOME/Library/Caches/ms-playwright"/chromium-* >/dev/null 2>&1; then
  echo "  !! 未发现 Playwright Chromium。首次使用会现场下载（慢），建议: npx playwright install chromium"
fi

echo ""
echo "✅ 迁移完成。请重启 pi（新开终端标签页以确保环境变量生效）。"

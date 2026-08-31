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

echo "==> [1/7] 安装 pi 包（幂等，重复安装无害）"
for pkg in \
  "npm:pi-lmstudio" \
  "npm:pi-mcp-adapter" \
  "npm:@houndmcp/hound-mcp-pi" \
  "npm:pi-subagents" \
  "npm:@ff-labs/pi-fff" \
  "npm:pi-hermes-memory" \
  "npm:@gotgenes/pi-permission-system" \
  "npm:pi-interactive-shell" \
  "npm:betterwright" \
  "npm:pi-espresso" \
  "npm:pi-powerline-footer@$POWERLINE_VERSION" \
  "npm:@juicesharp/rpiv-todo"; do
  echo "  - $pkg"
  pi install "$pkg" >/dev/null 2>&1 || { echo "  !! 安装失败: $pkg"; exit 1; }
done

echo "==> [2/7] 合并 powerline 配置与 TUI 全屏模式到 settings.json"
python3 - "$AGENT_DIR/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
powerline = {
    "preset": "ascii",
    "welcome": False,
    "layout": {
        "left": ["context_pct", "token_in", "cache_read", "token_total",
                 "cost", "cache_write", "path"],
        "right": ["model"],
    },
    "separator": "pipe",
    "cache_read": {"format": "both"},
}
with open(path) as f:
    data = json.load(f)
data["powerline"] = powerline
# pi >= 0.84.3: 默认全屏 TUI + 常驻滚动条（仅当用户未自行设置时写入，避免覆盖个人选择）
data.setdefault("tuiMode", "fullscreen")
data.setdefault("fullscreenScrollbar", "always")
# bash 模式 + 一次性 !/!! 命令的 ghost 补全（顶层键，非 powerline 下；setdefault 尊重用户已有设置）
data.setdefault("bashMode", {"completions": True})
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print("  settings.json powerline / tuiMode 已写入")
PY

echo "==> [3/7] 复制配置文件"
mkdir -p "$AGENT_DIR/extensions/powerline-footer" \
         "$AGENT_DIR/extensions/pi-permission-system" \
         "$CONFIG_MCP_DIR"
cp "$CFG/powerline-theme.json" "$AGENT_DIR/extensions/powerline-footer/theme.json"
cp "$CFG/permission-config.json" "$AGENT_DIR/extensions/pi-permission-system/config.json"
cp "$CFG/mcp.json" "$CONFIG_MCP_DIR/mcp.json"
# @ 引用增强扩展（Claude Code 风格：@../、@/绝对路径、@~/ 补全），全局自动发现 + /reload 热加载
cp "$CFG/at-anywhere.ts" "$AGENT_DIR/extensions/at-anywhere.ts"
echo "  theme.json / permission config / mcp.json / at-anywhere.ts 已复制"

echo "==> [4/7] 环境变量（~/.zshenv，幂等）"
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

echo "==> [5/7] 应用 powerline-footer 源码 patch（版本 ${POWERLINE_VERSION}）"
PFDIR="$NPM_DIR/pi-powerline-footer"
if [ ! -d "$PFDIR" ]; then
  echo "  !! 未找到 ${PFDIR}，无法应用 patch（请先重跑本脚本）"
  exit 1
fi

# 校验安装版本与 patch 锁定的版本一致，避免版本漂移导致 patch 失效
INSTALLED_VERSION="$(node -e "console.log(require('$PFDIR/package.json').version)" 2>/dev/null || echo unknown)"
if [ "$INSTALLED_VERSION" != "$POWERLINE_VERSION" ]; then
  echo "  !! powerline-footer 版本不匹配: 已装 ${INSTALLED_VERSION}，patch 针对 ${POWERLINE_VERSION}。"
  echo "  请手动安装 $POWERLINE_VERSION 后再重跑: pi install npm:pi-powerline-footer@$POWERLINE_VERSION"
  exit 1
fi

# ① 冲突预检：-N 正向 dry-run 的退出码仅在“全部干净可应用”时可靠（exit 0），
#    其余情况用输出文本判断（hunks failed = 旧版残留/源码损坏）。
#    注意：纯追加型 hunk（如 editor.ts）patch 无法检测“已应用”，
#    因此“是否已应用”交给下面的特征行全集判定，不用 dry-run。
set +e
PATCH_STATE="$(cd "$PFDIR" && patch -p1 -N --dry-run < "$PATCHES/powerline.patch" 2>&1)"
PATCH_EXIT=$?
set -e

# ② 特征行全集判定“最新 patch 是否完整在位”。
#    每个文件取一行最新 patch 独有的特征；升级 patch 时需同步维护此列表。
MISSING=""
grep -q 'Fire onChange' "$PFDIR/bash-mode/editor.ts"  || MISSING="$MISSING editor.ts"
grep -q 'minimal: "minimal"' "$PFDIR/icons.ts"         || MISSING="$MISSING icons.ts"
grep -q 'msgTpsValue' "$PFDIR/index.ts"                || MISSING="$MISSING index.ts"
grep -q 'tps.toFixed(1)' "$PFDIR/segments.ts"          || MISSING="$MISSING segments.ts"
grep -q 'extMsgTps: number | null' "$PFDIR/types.ts"   || MISSING="$MISSING types.ts"

repair_and_apply() {  # 重装还原干净源码后统一应用 patch
  local reason="$1"
  echo "  !! ${reason}，自动重装 ${POWERLINE_VERSION} 还原源码后重新应用..."
  # pi install 对已装的同版本是静默幂等的（不覆盖文件），必须先移除目录
  rm -rf "$PFDIR"
  pi install "npm:pi-powerline-footer@$POWERLINE_VERSION" >/dev/null 2>&1 || {
    echo "  !! 重装 ${POWERLINE_VERSION} 失败，请手动执行: pi install npm:pi-powerline-footer@$POWERLINE_VERSION"
    exit 1
  }
  if ! (cd "$PFDIR" && patch -p1 < "$PATCHES/powerline.patch" >/dev/null); then
    echo "  !! 在干净的 ${POWERLINE_VERSION} 上应用 patch 仍失败，请重新生成 patches/powerline.patch"
    exit 1
  fi
  echo "  patch 已重新应用（${reason} 已清理）"
}

if echo "$PATCH_STATE" | grep -qiE "hunks? failed"; then
  # 旧版 patch 残留或源码损坏：其他文件与 patch 期望不一致，直接重装还原
  repair_and_apply "检测到旧版 patch 残留或源码不一致"
elif [ -z "$MISSING" ]; then
  # 全部特征行在位 = 已应用当前最新 patch
  echo "  patch 已是最新版本，跳过"
elif [ $PATCH_EXIT -eq 0 ]; then
  # 全新安装：dry-run 全部干净且特征缺失 → 直接应用
  if ! (cd "$PFDIR" && patch -p1 < "$PATCHES/powerline.patch" >/dev/null); then
    echo "  !! patch 应用失败，请检查 $PATCHES/powerline.patch"
    exit 1
  fi
  echo "  patch 已应用"
else
  # 罕见的混合状态（如部分文件被还原）：保守重装，避免纯追加 hunk 重复打入
  repair_and_apply "检测到 patch 部分缺失（$MISSING）"
fi

echo "==> [6/7] 安装 BetterChromium（BetterWright 托管浏览器，走镜像加速）"
bash "$SCRIPT_DIR/scripts/install-betterchromium.sh"

echo "==> [7/7] 环境检查"
which pi >/dev/null 2>&1 || { echo "  !! 未找到 pi，请先安装 pi coding agent"; exit 1; }
if ! which hound >/dev/null 2>&1; then
  echo "  !! 未找到 hound（web 搜索工具）。安装: pip install hound-mcp[all]"
fi
if ! ls "$HOME/Library/Caches/ms-playwright"/chromium-* >/dev/null 2>&1; then
  echo "  !! 未发现 Playwright Chromium。首次使用会现场下载（慢），建议: npx playwright install chromium"
fi
if ! ls "$HOME/.betterwright/chromium"/*/ >/dev/null 2>&1; then
  echo "  !! 未发现 BetterChromium（BetterWright 浏览器）。重跑: bash scripts/install-betterchromium.sh"
fi

echo ""
echo "✅ 迁移完成。请重启 pi（新开终端标签页以确保环境变量生效）。"

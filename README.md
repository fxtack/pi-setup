# pi-setup — Pi 环境一键迁移包

一套命令把本机的 pi 插件、配置和显示定制迁移到任何新环境。

默认是纯配置 + 脚本部署；部分显示效果需要 `patches/powerline.patch`（见下方版本说明）。

## 包含内容

| 资产 | 说明 |
|---|---|
| `install.sh` | 一键部署脚本（幂等，可重复执行） |
| `configs/mcp.json` | Playwright MCP 服务器配置 → `~/.config/mcp/mcp.json` |
| `configs/powerline-theme.json` | footer 图标文字定制 → `~/.pi/agent/extensions/powerline-footer/theme.json` |
| `configs/permission-config.json` | 权限插件策略（含 yoloMode）→ `~/.pi/agent/extensions/pi-permission-system/config.json` |
| `patches/powerline.patch` | footer 源码 patch（思考级别完整文本 / off+max / i/o 合并 / TPS 显示于模型名左侧 / cached 格式+命中率 / 右对齐布局 / `!` 边框反馈 / 宽度安全钳制，防超宽崩溃 pi） |

## 使用方法

### 新机器部署（推荐 git clone）

```bash
# 1. 克隆仓库（或直接下载 ZIP）
git clone https://github.com/fxtack/pi-setup.git
cd pi-setup

# 2. 执行一键部署（脚本用相对路径定位资源，放哪个目录都行）
bash install.sh

# 3. 新开终端标签页，启动 pi
```

> 也可以 `scp -r ~/Project/pi-setup user@newhost:~` 拷贝目录后 `bash pi-setup/install.sh`。

脚本会自动：
1. `pi install` 全部 12 个包（lmstudio、mcp-adapter、hound、subagents、fff、hermes-memory、permission-system、interactive-shell、betterwright、powerline-footer、rpiv-todo）
2. 合并 powerline 布局/预设/分隔符 + TUI 全屏模式（`tuiMode`/`fullscreenScrollbar`，需 pi ≥ 0.84.3）到 `settings.json`
3. 复制 3 个配置文件到正确位置
4. 写入 `~/.zshenv` 环境变量（`POWERLINE_NERD_FONTS=0`、`~/.pi/agent/bin` PATH）
5. 应用 powerline-footer 源码 patch（三态检测：干净源码直接应用 / 已是最新自动跳过 / 旧版残留自动重装修复）
6. 环境检查（pi / hound / Playwright Chromium）

## 升级扩展后恢复 patch

```bash
cd ~/.pi/agent/npm/node_modules/pi-powerline-footer
patch -p1 < ~/Project/pi-setup/patches/powerline.patch
```

或直接重跑 `install.sh`。patch 步骤采用「dry-run 冲突预检 + 特征行全集判定」：

| 检测结果 | 含义 | 动作 |
|---|---|---|
| 特征行全部在位 | 已应用当前最新 patch | 跳过 |
| 特征缺失 + dry-run 干净 | 官方原版源码（新机器） | 直接打 patch |
| dry-run 报 `hunks failed` | 旧版 patch 残留 / 源码损坏 | 自动重装 0.16.0 还原后重打 |
| 特征部分缺失 + dry-run 非干净 | 混合状态（部分文件被还原） | 保守重装后统一重打 |

> ⚠️ 已知坑：
> - `pi install` 对**已安装的同版本**包是静默幂等的，**不会覆盖文件**。
>   所以当 patch 演进后重跑脚本，若旧版 patch 仍残留在源码里，脚本会检测到 `hunks failed`
>   并自动执行「移除目录 → 重装 → 重打 patch」，无需手动干预。
> - 纯追加型 hunk（如 editor.ts）patch 无法检测「已应用」，重复执行会重复追加；
>   因此脚本改用每个文件一行**特征行**判定（`install.sh` 第 5 步的 `MISSING` 列表），
>   升级 patch 时需同步更新该列表。

## 依赖说明（脚本无法自动装的部分）

- **hound**（web 搜索工具）：`pip install hound-mcp[all]`
- **Playwright Chromium**：`npx playwright install chromium`（国内网络建议 `PLAYWRIGHT_DOWNLOAD_HOST=https://npmmirror.com/mirrors/playwright/`）
- **lmstudio** 如需连本地模型：新机器需自行安装 LM Studio

## 注意事项（重要）

⚠️ **powerline-footer 版本被锁定为 0.16.0**（`install.sh` 用 `npm:pi-powerline-footer@0.16.0` 安装并校验版本）。
`patches/powerline.patch` 是针对 0.16.0 源码生成的，如果升级到更高版本，
patch 可能无法应用。升级流程：

1. 在新版本上重新验证 / 重新生成 `patches/powerline.patch`
2. 更新 `install.sh` 里的 `POWERLINE_VERSION`
3. 更新 `pi-setup/README.md` 的版本说明

`install.sh` 启动时会检查目录结构、锁定版本，patch 步骤用 `patch -p1 -N --dry-run` 三态检测：
干净源码直接应用；已应用最新则跳过；旧版残留或源码不一致则自动重装修复。
**不会**在状态不一致时静默继续或静默跳过。

- 脚本会**覆盖**目标机器的 powerline / 权限插件 / mcp 配置，部署前确认目标机无更重要的本地定制
- `settings.json` 只合并 `powerline` 键，其他键（模型、主题等）保持不动
- 其余 8 个包（除 powerline 外）不锁版本，跟随 `latest`

# Pi 环境迁移包

一套命令把本机的 pi 插件、配置和显示定制迁移到任何新环境。

## 包含内容

| 资产 | 说明 |
|---|---|
| `install.sh` | 一键部署脚本（幂等，可重复执行） |
| `configs/mcp.json` | Playwright MCP 服务器配置 → `~/.config/mcp/mcp.json` |
| `configs/powerline-theme.json` | footer 图标文字定制 → `~/.pi/agent/extensions/powerline-footer/theme.json` |
| `configs/permission-config.json` | 权限插件策略（含 yoloMode）→ `~/.pi/agent/extensions/pi-permission-system/config.json` |
| `patches/powerline.patch` | footer 源码 patch（思考级别完整文本 / off+max / i/o 合并 / cached 格式） |

## 使用方法

### 新机器部署

```bash
# 1. 拷贝整个 setup 目录到新机器（任意位置，如 ~/Project/setup/）
scp -r ~/Project/setup user@newhost:~/

# 2. 新机器上执行
bash ~/setup/install.sh

# 3. 新开终端标签页，启动 pi
```

脚本会自动：
1. `pi install` 全部 9 个包（lmstudio、mcp-adapter、hound、subagents、fff、hermes-memory、permission-system、powerline-footer、rpiv-todo）
2. 合并 powerline 布局/预设/分隔符到 `settings.json`
3. 复制 3 个配置文件到正确位置
4. 写入 `~/.zshenv` 环境变量（`POWERLINE_NERD_FONTS=0`、`~/.pi/agent/bin` PATH）
5. 应用 powerline-footer 源码 patch（已检测幂等，重复执行自动跳过）
6. 环境检查（pi / hound / Playwright Chromium）

## 升级扩展后恢复 patch

```bash
cd ~/.pi/agent/npm/node_modules/pi-powerline-footer
patch -p1 < ~/Project/setup/patches/powerline.patch
```

或直接重跑 `install.sh`（自动检测并跳过已应用部分）。

## 依赖说明（脚本无法自动装的部分）

- **hound**（web 搜索工具）：`pip install hound-mcp[all]`
- **Playwright Chromium**：`npx playwright install chromium`（国内网络建议 `PLAYWRIGHT_DOWNLOAD_HOST=https://npmmirror.com/mirrors/playwright/`）
- **lmstudio** 如需连本地模型：新机器需自行安装 LM Studio

## 注意

- 脚本会**覆盖**目标机器的 powerline / 权限插件 / mcp 配置，部署前确认目标机无更重要的本地定制
- `settings.json` 只合并 `powerline` 键，其他键（模型、主题等）保持不动

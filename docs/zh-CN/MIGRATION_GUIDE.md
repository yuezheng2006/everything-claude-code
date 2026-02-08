# Claude Code 配置迁移指南

本指南介绍如何使用 `migrate-ecc.sh` 脚本将 Everything Claude Code (ECC) 配置应用到您自己的项目中。

---

## 快速开始

```bash
# 克隆或下载仓库
git clone https://github.com/affaan-m/everything-claude-code.git
cd everything-claude-code

# 运行交互式迁移到当前项目
bash scripts/migrate-ecc.sh

# 或非交互式运行到指定目录
bash scripts/migrate-ecc.sh --force --scope project -l typescript -c agents -c commands -c rules /path/to/your/project
```

---

## 安装了什么？

| 组件 | 描述 | 文件位置 |
|------|------|----------|
| **Agents** | 专业子代理 (planner、code-reviewer、tdd-guide 等) | `.claude/agents/*.md` |
| **Commands** | 斜杠命令 (/plan、/tdd、/code-review、/e2e 等) | `.claude/commands/*.md` |
| **Skills** | 工作流定义和领域知识 | `.claude/skills/*.md` |
| **Rules** | 必须遵循的准则 (编码风格、测试、安全) | `.claude/rules/*.md` |
| **Plugins** | 插件清单和配置 | `.claude/plugins/*` |
| **Hooks** | 基于触发的自动化 (格式化、检查、提醒) | `.claude/settings.json` (合并) |
| **Contexts** | 动态系统提示上下文 | `.claude/contexts/*.md` |
| **MCP Configs** | MCP 服务器配置 | `.mcp.json` (项目根目录) |

---

## 安装方法

### 方法 1: 插件安装 (推荐给大多数用户)

如果您只想在所有项目中使用 ECC：

```bash
# 作为 Claude Code 插件安装
/plugin install everything-claude-code@everything-claude-code

# 或克隆并本地安装
git clone https://github.com/affaan-m/everything-claude-code.git ~/.claude/plugins/everything-claude-code
```

**注意:** 插件系统不支持分发 `rules`。需要使用方法 2 手动安装规则。

### 方法 2: 迁移脚本 (用于项目特定定制)

当您需要以下情况时使用 `migrate-ecc.sh`：
- 自定义要安装的组件
- 使用特定语言的规则 (TypeScript、Python、Go)
- 使用本地化文档 (中文等)
- 项目级别的 hooks 和 MCP 配置
- 与现有配置合并

---

## 迁移脚本选项

### 基本用法

```bash
bash scripts/migrate-ecc.sh [选项] [目标目录]
```

### 选项说明

| 选项 | 描述 |
|------|------|
| `-s, --scope <user\|project>` | 安装范围：`user` 安装到 `~/.claude/`，`project` 安装到 `.claude/` |
| `-l, --lang <lang>` | 语言规则 (可重复)：`typescript`、`python`、`golang` |
| `-c, --component <name>` | 要安装的组件 (可重复)：`agents`、`commands`、`skills`、`rules`、`plugins`、`hooks`、`contexts`、`mcp-configs` |
| `-L, --locale <locale>` | 使用本地化文档：`zh-CN`、`zh-TW` |
| `-r, --repo <path>` | 使用本地仓库而不是克隆 |
| `-d, --dry-run` | 显示将要执行的操作但不实际更改 |
| `-f, --force` | 跳过所有确认提示 |
| `-b, --backup` | 强制备份现有配置 |
| `--no-backup` | 即使存在配置也不备份 |
| `-h, --help` | 显示帮助信息 |
| `-v, --version` | 显示版本 |

### 使用示例

```bash
# 交互模式 (推荐 - 引导您完成选择)
bash scripts/migrate-ecc.sh

# 安装到当前项目，包含 TypeScript 规则
bash scripts/migrate-ecc.sh -s project -l typescript .

# 安装到用户级别，包含所有语言
bash scripts/migrate-ecc.sh -s user -l typescript -l python -l golang

# 干运行，查看将要发生什么
bash scripts/migrate-ecc.sh --dry-run -s project ~/my-project

# 使用中文 (zh-CN) 本地化内容
bash scripts/migrate-ecc.sh -L zh-CN -s project -l typescript .

# 完整安装到指定项目
bash scripts/migrate-ecc.sh \
  --force \
  --scope project \
  --lang typescript \
  --lang python \
  --component agents \
  --component commands \
  --component skills \
  --component rules \
  --component hooks \
  --component contexts \
  /path/to/project
```

---

## 输出文件

迁移后，您的项目将包含：

```
your-project/
├── .claude/
│   ├── agents/           # 子代理定义
│   │   ├── planner.md
│   │   ├── code-reviewer.md
│   │   └── ...
│   ├── commands/         # 斜杠命令
│   │   ├── plan.md
│   │   ├── tdd.md
│   │   └── ...
│   ├── skills/           # 领域知识
│   │   └── ...
│   ├── rules/            # 必须遵循的准则
│   │   ├── coding-style.md
│   │   ├── testing.md
│   │   ├── typescript/
│   │   └── ...
│   ├── contexts/         # 系统提示上下文
│   │   ├── dev.md
│   │   └── ...
│   ├── scripts/hooks/    # Hook 脚本
│   │   ├── check-console-log.js
│   │   └── ...
│   ├── scripts/lib/      # Hook 依赖 (utils、package-manager 等)
│   │   └── ...
│   └── settings.json     # Hooks 配置
└── .mcp.json            # MCP 服务器配置 (新增!)
```

---

## 与插件安装的区别

| 方面 | 插件方法 | 迁移脚本 |
|------|----------|----------|
| 范围 | 用户级 (`~/.claude/`) | 用户或项目级 |
| 规则 | 不支持 | 完全支持 |
| 本地化 | 仅英文 | zh-CN、zh-TW 带英文回退 |
| MCP 配置 | 手动 | 自动到 `.mcp.json` |
| Hooks | 通过插件系统 | 转换为官方格式 |
| 备份 | 无 | 有 (带时间戳) |

---

## 主要特性

### 1. 符合官方格式

迁移脚本将弃用的格式转换为官方 Claude Code 格式：

- **Hooks**: 将表达式匹配器 (`tool == "Bash" && ...`) 转换为简单正则匹配器 (`"Bash"`)
- **MCP 配置**: 写入 `.mcp.json` (项目范围) 而不是 `.claude.json`
- **Settings**: Hooks 正确合并到 `.claude/settings.json`

### 2. 带回退的本地化支持

```bash
# 使用中文文档和英文回退
bash scripts/migrate-ecc.sh -L zh-CN -s project .
```

这将安装：
- 来自 `docs/zh-CN/` 的中文内容 (agents、commands、skills、rules、contexts)
- 缺失翻译的英文内容
- 脚本和 hooks 始终使用原始英文

### 3. 智能合并

现有配置将被保留：
- 现有的 agents/commands/skills 被保留
- Hooks 被合并 (按描述去重)
- MCP 服务器被合并 (跳过重复项)

### 4. 迁移前备份

现有的 `.claude/` 目录将被备份：
```
your-project/.claude-backup-20250208-143022/
```

---

## 安装后步骤

### 1. 配置 MCP 服务器

编辑 `.mcp.json` 添加您的 API 密钥：

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "您的实际令牌"
      }
    }
  }
}
```

### 2. 检查 Hooks

检查 `.claude/settings.json` 验证 hooks 配置正确：

```bash
cat .claude/settings.json
```

某些 hooks 引用 `$CLAUDE_PROJECT_DIR` - 验证路径是否正确。

### 3. 验证安装

```bash
# 检查 Claude Code 版本 (需要 v2.1.0+)
claude --version

# 尝试一个命令
/plan "添加用户认证"
```

---

## 故障排除

### 问题: "未找到 Node.js"

**解决方案:** 安装 Node.js 以启用 JSON 合并和 hooks 转换：

```bash
# macOS
brew install node

# Ubuntu/Debian
sudo apt install nodejs npm

# 或使用 nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
nvm install node
```

### 问题: "Hooks 不工作"

**原因:** 迁移脚本将弃用的表达式匹配器转换为官方格式。

**解决方案:** 检查 `.claude/settings.json` 是否使用简单的正则匹配器：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [...]
      }
    ]
  }
}
```

### 问题: MCP 服务器无法连接

**原因:** `.mcp.json` 格式或 API 密钥未配置。

**解决方案:**
1. 验证 `.mcp.json` 在项目根目录 (不是 `.claude.json`)
2. 将 `YOUR_*_HERE` 占位符替换为实际 API 密钥
3. 使用 `claude mcp list` 验证服务器状态

### 问题: 未创建备份

**原因:** 使用了 `--no-backup` 标志或未检测到现有配置。

**解决方案:** 移除 `--no-backup` 标志或在迁移前手动备份。

### 问题: 路径引用断开

**原因:** hooks 中的 `${CLAUDE_PLUGIN_ROOT}` 引用。

**解决方案:** 脚本将这些替换为 `$CLAUDE_PROJECT_DIR/.claude`。验证路径存在：

```bash
ls -la .claude/scripts/hooks/
```

---

## 从旧版本迁移

如果您之前使用过旧版本的 ECC：

1. **先备份:**
   ```bash
   cp -r ~/.claude ~/.claude.backup
   cp -r your-project/.claude your-project/.claude.backup
   ```

2. **运行迁移:**
   ```bash
   bash scripts/migrate-ecc.sh --force --backup .
   ```

3. **检查合并的文件:**
   - 检查 `.claude/settings.json` 是否有 hooks 冲突
   - 检查 `.mcp.json` 是否有 MCP 服务器重复

4. **清理旧文件:**
   - 删除 `.claude.json` (已被 `.mcp.json` 替代)
   - 删除 `.claude/hooks.json` (已合并到 `settings.json`)

---

## 卸载

从项目中移除 ECC：

```bash
# 删除 .claude 目录
rm -rf .claude

# 删除 .mcp.json
rm .mcp.json

# 或从备份恢复 (如果有)
cp -r .claude-backup-*/.claude .
```

---

## 高级用法

### 自定义本地仓库

使用本地 fork 或修改版本：

```bash
bash scripts/migrate-ecc.sh --repo ./my-ecc-fork -s project .
```

### 选择性组件安装

只安装您需要的内容：

```bash
# 仅 TypeScript 的 agents 和 rules
bash scripts/migrate-ecc.sh -c agents -c rules -l typescript .

# 仅 hooks 和 MCP 配置
bash scripts/migrate-ecc.sh -c hooks -c mcp-configs .
```

### 特定本地化安装

```bash
# 简体中文带英文回退
bash scripts/migrate-ecc.sh -L zh-CN -s project .

# 繁体中文带英文回退
bash scripts/migrate-ecc.sh -L zh-TW -s project .
```

---

## 贡献

发现迁移脚本有问题？请报告：

1. 检查现有问题：https://github.com/affaan-m/everything-claude-code/issues
2. 创建包含详细信息的新问题
3. 或提交包含您的修复的 PR

---

## 另请参阅

- [主 README](../README.md) - ECC 概述
- [插件安装指南](../README.md#plugin-installation) - 作为插件安装
- [规则 README](../rules/README.md) - 规则结构和用法
- [Claude Code 文档](https://docs.anthropic.com/en/docs/claude-code) - 官方文档

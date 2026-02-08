# Claude Code Configuration Migration Guide

This guide explains how to apply Everything Claude Code (ECC) configurations to your own projects using the `migrate-ecc.sh` script.

---

## Quick Start

```bash
# Clone or download the repo
git clone https://github.com/affaan-m/everything-claude-code.git
cd everything-claude-code

# Run interactive migration to your current project
bash scripts/migrate-ecc.sh

# Or run non-interactively to a specific directory
bash scripts/migrate-ecc.sh --force --scope project -l typescript -c agents -c commands -c rules /path/to/your/project
```

---

## What Gets Installed?

| Component | Description | Files |
|-----------|-------------|-------|
| **Agents** | Specialized subagents (planner, code-reviewer, tdd-guide, etc.) | `.claude/agents/*.md` |
| **Commands** | Slash commands (/plan, /tdd, /code-review, /e2e, etc.) | `.claude/commands/*.md` |
| **Skills** | Workflow definitions and domain knowledge | `.claude/skills/*.md` |
| **Rules** | Always-follow guidelines (coding style, testing, security) | `.claude/rules/*.md` |
| **Plugins** | Plugin manifests and configurations | `.claude/plugins/*` |
| **Hooks** | Trigger-based automations (format, lint, reminders) | `.claude/settings.json` (merged) |
| **Contexts** | Dynamic system prompt contexts | `.claude/contexts/*.md` |
| **MCP Configs** | MCP server configurations | `.mcp.json` (project root) |

---

## Installation Methods

### Method 1: Plugin Installation (Recommended for most users)

If you just want to use ECC across all your projects:

```bash
# Install as a Claude Code plugin
/plugin install everything-claude-code@everything-claude-code

# Or clone and install locally
git clone https://github.com/affaan-m/everything-claude-code.git ~/.claude/plugins/everything-claude-code
```

**Note:** The plugin system does not support distributing `rules`. Install rules manually using Method 2.

### Method 2: Migration Script (For project-specific customization)

Use `migrate-ecc.sh` when you need to:
- Customize which components to install
- Use language-specific rules (TypeScript, Python, Go)
- Use localized documentation (Chinese, etc.)
- Have project-level hooks and MCP configurations
- Merge with existing configurations

---

## Migration Script Options

### Basic Usage

```bash
bash scripts/migrate-ecc.sh [OPTIONS] [TARGET_DIR]
```

### Options

| Option | Description |
|--------|-------------|
| `-s, --scope <user\|project>` | Installation scope: `user` for `~/.claude/`, `project` for `.claude/` |
| `-l, --lang <lang>` | Language rules to install (repeatable): `typescript`, `python`, `golang` |
| `-c, --component <name>` | Components to install (repeatable): `agents`, `commands`, `skills`, `rules`, `plugins`, `hooks`, `contexts`, `mcp-configs` |
| `-L, --locale <locale>` | Use localized docs: `zh-CN`, `zh-TW` |
| `-r, --repo <path>` | Use local repo instead of cloning |
| `-d, --dry-run` | Show what would be done without changes |
| `-f, --force` | Skip all confirmation prompts |
| `-b, --backup` | Force backup of existing config |
| `--no-backup` | Skip backup even if config exists |
| `-h, --help` | Show help message |
| `-v, --version` | Show version |

### Examples

```bash
# Interactive mode (recommended - guides you through choices)
bash scripts/migrate-ecc.sh

# Install to current project with TypeScript rules
bash scripts/migrate-ecc.sh -s project -l typescript .

# Install to user-level with all languages
bash scripts/migrate-ecc.sh -s user -l typescript -l python -l golang

# Dry run to see what would happen
bash scripts/migrate-ecc.sh --dry-run -s project ~/my-project

# Use Chinese (zh-CN) localized content
bash scripts/migrate-ecc.sh -L zh-CN -s project -l typescript .

# Full installation to a specific project
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

## Output Files

After migration, your project will have:

```
your-project/
├── .claude/
│   ├── agents/           # Subagent definitions
│   │   ├── planner.md
│   │   ├── code-reviewer.md
│   │   └── ...
│   ├── commands/         # Slash commands
│   │   ├── plan.md
│   │   ├── tdd.md
│   │   └── ...
│   ├── skills/           # Domain knowledge
│   │   └── ...
│   ├── rules/            # Always-follow guidelines
│   │   ├── coding-style.md
│   │   ├── testing.md
│   │   ├── typescript/
│   │   └── ...
│   ├── contexts/         # System prompt contexts
│   │   ├── dev.md
│   │   └── ...
│   ├── scripts/hooks/    # Hook scripts
│   │   ├── check-console-log.js
│   │   └── ...
│   ├── scripts/lib/      # Hook dependencies (utils, package-manager, etc.)
│   │   └── ...
│   └── settings.json     # Hooks configuration
└── .mcp.json            # MCP server configurations (NEW!)
```

---

## What's Different from Plugin Installation?

| Aspect | Plugin Method | Migration Script |
|--------|--------------|------------------|
| Scope | User-level (`~/.claude/`) | User or project-level |
| Rules | Not supported | Full support |
| Localization | English only | zh-CN, zh-TW with English fallback |
| MCP Configs | Manual | Automatic to `.mcp.json` |
| Hooks | Via plugin system | Converted to official format |
| Backup | No | Yes (with timestamp) |

---

## Key Features

### 1. Official Format Compliance

The migration script converts deprecated formats to official Claude Code formats:

- **Hooks**: Converts expression-based matchers (`tool == "Bash" && ...`) to simple regex matchers (`"Bash"`)
- **MCP Configs**: Writes to `.mcp.json` (project-scoped) instead of `.claude.json`
- **Settings**: Hooks properly merged into `.claude/settings.json`

### 2. Locale Support with Fallback

```bash
# Use Chinese documentation with English fallback
bash scripts/migrate-ecc.sh -L zh-CN -s project .
```

This installs:
- Chinese content from `docs/zh-CN/` (agents, commands, skills, rules, contexts)
- English content for missing translations
- Scripts and hooks always use original English

### 3. Smart Merging

Existing configurations are preserved:
- Existing agents/commands/skills are kept
- Hooks are merged (deduplicated by description)
- MCP servers are merged (skips duplicates)

### 4. Backup Before Migration

Existing `.claude/` directories are backed up:
```
your-project/.claude-backup-20250208-143022/
```

---

## Post-Installation Steps

### 1. Configure MCP Servers

Edit `.mcp.json` to add your API keys:

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "your_actual_token_here"
      }
    }
  }
}
```

### 2. Review Hooks

Check `.claude/settings.json` to verify hooks are configured correctly:

```bash
cat .claude/settings.json
```

Some hooks reference `$CLAUDE_PROJECT_DIR` - verify paths are correct.

### 3. Verify Installation

```bash
# Check Claude Code version (requires v2.1.0+)
claude --version

# Try a command
/plan "Add user authentication"
```

---

## Troubleshooting

### Issue: "Node.js not found"

**Solution:** Install Node.js to enable JSON merging and hooks conversion:

```bash
# macOS
brew install node

# Ubuntu/Debian
sudo apt install nodejs npm

# Or use nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
nvm install node
```

### Issue: "Hooks not working"

**Cause:** The migration script converts deprecated expression-based matchers to the official format.

**Solution:** Check that `.claude/settings.json` uses simple regex matchers:

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

### Issue: MCP servers not connecting

**Cause:** `.mcp.json` format or API keys not configured.

**Solution:**
1. Verify `.mcp.json` is in project root (not `.claude.json`)
2. Replace `YOUR_*_HERE` placeholders with actual API keys
3. Use `claude mcp list` to verify server status

### Issue: Backup not created

**Cause:** Using `--no-backup` flag or existing config not detected.

**Solution:** Remove `--no-backup` flag or manually backup before migration.

### Issue: Path references broken

**Cause:** `${CLAUDE_PLUGIN_ROOT}` references in hooks.

**Solution:** The script replaces these with `$CLAUDE_PROJECT_DIR/.claude`. Verify the paths exist:

```bash
ls -la .claude/scripts/hooks/
```

---

## Migration from Previous Versions

If you previously used an older version of ECC:

1. **Backup first:**
   ```bash
   cp -r ~/.claude ~/.claude.backup
   cp -r your-project/.claude your-project/.claude.backup
   ```

2. **Run migration:**
   ```bash
   bash scripts/migrate-ecc.sh --force --backup .
   ```

3. **Review merged files:**
   - Check `.claude/settings.json` for hook conflicts
   - Check `.mcp.json` for MCP server duplicates

4. **Clean up old files:**
   - Remove `.claude.json` (replaced by `.mcp.json`)
   - Remove `.claude/hooks.json` (merged into `settings.json`)

---

## Uninstallation

To remove ECC from your project:

```bash
# Remove .claude directory
rm -rf .claude

# Remove .mcp.json
rm .mcp.json

# Or restore from backup if available
cp -r .claude-backup-*/.claude .
```

---

## Advanced Usage

### Custom Local Repository

Use a local fork or modified version:

```bash
bash scripts/migrate-ecc.sh --repo ./my-ecc-fork -s project .
```

### Selective Component Installation

Install only what you need:

```bash
# Just agents and rules for TypeScript
bash scripts/migrate-ecc.sh -c agents -c rules -l typescript .

# Just hooks and MCP configs
bash scripts/migrate-ecc.sh -c hooks -c mcp-configs .
```

### Locale-Specific Installation

```bash
# Chinese (Simplified) with English fallback
bash scripts/migrate-ecc.sh -L zh-CN -s project .

# Chinese (Traditional) with English fallback
bash scripts/migrate-ecc.sh -L zh-TW -s project .
```

---

## Contributing

Found an issue with the migration script? Please report it:

1. Check existing issues: https://github.com/affaan-m/everything-claude-code/issues
2. Create a new issue with details
3. Or submit a PR with your fix

---

## See Also

- [Main README](../README.md) - Overview of ECC
- [Plugin Installation Guide](../README.md#plugin-installation) - Install as plugin
- [Rules README](../rules/README.md) - Rules structure and usage
- [Claude Code Documentation](https://docs.anthropic.com/en/docs/claude-code) - Official docs

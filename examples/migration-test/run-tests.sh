#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# migrate-ecc.sh 测试脚本
# 测试 5 个场景，验证迁移脚本的正确性
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MIGRATE="$REPO_DIR/scripts/migrate-ecc.sh"
TEST_BASE="$REPO_DIR/examples/migration-test"
PASS=0
FAIL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

assert_exists() {
  if [[ -e "$1" ]]; then
    echo -e "  ${GREEN}PASS${NC} $2"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $2 (not found: $1)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_exists() {
  if [[ ! -e "$1" ]]; then
    echo -e "  ${GREEN}PASS${NC} $2"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $2 (should not exist: $1)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  if grep -q "$2" "$1" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $3"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $3 (pattern '$2' not found in $1)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_count_ge() {
  local dir="$1"
  local min="$2"
  local label="$3"
  local count
  count=$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$count" -ge "$min" ]]; then
    echo -e "  ${GREEN}PASS${NC} $label ($count files >= $min)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $label ($count files < $min)"
    FAIL=$((FAIL + 1))
  fi
}

# ============================================================================
echo -e "\n${BOLD}${CYAN}=== 测试 1: 空项目 - 全量安装 ===${NC}\n"
# ============================================================================

TARGET="$TEST_BASE/test-run-1"
rm -rf "$TARGET" && mkdir -p "$TARGET"

bash "$MIGRATE" \
  --force --repo "$REPO_DIR" --scope project \
  --lang typescript --lang python --lang golang \
  --component agents --component commands --component skills \
  --component rules --component plugins --component hooks --component contexts \
  --component mcp-configs \
  "$TARGET" >/dev/null 2>&1

assert_exists "$TARGET/.claude/agents/planner.md" "agents/planner.md 已安装"
assert_exists "$TARGET/.claude/agents/code-reviewer.md" "agents/code-reviewer.md 已安装"
assert_exists "$TARGET/.claude/commands/tdd.md" "commands/tdd.md 已安装"
assert_exists "$TARGET/.claude/commands/plan.md" "commands/plan.md 已安装"
assert_exists "$TARGET/.claude/skills" "skills/ 目录已创建"
assert_exists "$TARGET/.claude/rules/coding-style.md" "rules/coding-style.md (common) 已安装"
assert_exists "$TARGET/.claude/rules/testing.md" "rules/testing.md (common) 已安装"
assert_exists "$TARGET/.claude/settings.json" "settings.json (hooks) 已安装"
assert_exists "$TARGET/.claude/contexts/dev.md" "contexts/dev.md 已安装"
assert_exists "$TARGET/.mcp.json" ".mcp.json (MCP) 已安装"
assert_exists "$TARGET/.claude/plugins" "plugins/ 目录已创建"
assert_file_count_ge "$TARGET/.claude/agents" 10 "agents 文件数 >= 10"
assert_file_count_ge "$TARGET/.claude/commands" 20 "commands 文件数 >= 20"
assert_contains "$TARGET/.claude/settings.json" "hooks" "settings.json 包含 hooks 配置"

# ============================================================================
echo -e "\n${BOLD}${CYAN}=== 测试 2: 已有配置 - 合并安装 + 备份 ===${NC}\n"
# ============================================================================

TARGET="$TEST_BASE/test-run-2"
rm -rf "$TARGET" && mkdir -p "$TARGET/.claude/agents"

# 创建已有配置
echo '{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo existing"}],"description":"My existing hook"}]}}' \
  > "$TARGET/.claude/settings.json"
cat > "$TARGET/.claude/agents/my-agent.md" <<'AGENT'
---
name: my-agent
---
Custom agent
AGENT

bash "$MIGRATE" \
  --force --backup --repo "$REPO_DIR" --scope project \
  --lang typescript \
  --component agents --component hooks \
  "$TARGET" >/dev/null 2>&1

assert_exists "$TARGET/.claude/agents/my-agent.md" "自定义 agent 保留"
assert_exists "$TARGET/.claude/agents/planner.md" "ECC agent 已合并"
assert_contains "$TARGET/.claude/settings.json" "My existing hook" "已有 hook 保留"
assert_exists "$TARGET/.claude/scripts/hooks/hook-filter-1.js" "ECC hook 脚本已创建 (tmux 提醒)"
assert_exists "$TARGET/.claude/scripts/lib/utils.js" "Hook 依赖 lib 已安装"
assert_exists "$TARGET/.claude/scripts/lib/package-manager.js" "Hook 依赖 package-manager 已安装"
# 检查备份
BACKUP_DIR=$(ls -d "$TARGET"/.claude-backup-* 2>/dev/null | head -1)
if [[ -n "$BACKUP_DIR" ]]; then
  assert_exists "$BACKUP_DIR/agents/my-agent.md" "备份包含原始 agent"
  assert_exists "$BACKUP_DIR/settings.json" "备份包含原始 settings.json"
else
  echo -e "  ${RED}FAIL${NC} 备份目录未创建"
  FAIL=$((FAIL + 2))
fi

# ============================================================================
echo -e "\n${BOLD}${CYAN}=== 测试 3: 仅 TypeScript 规则 ===${NC}\n"
# ============================================================================

TARGET="$TEST_BASE/test-run-3"
rm -rf "$TARGET" && mkdir -p "$TARGET"

bash "$MIGRATE" \
  --force --repo "$REPO_DIR" --scope project \
  --lang typescript \
  --component rules \
  "$TARGET" >/dev/null 2>&1

assert_exists "$TARGET/.claude/rules/coding-style.md" "common rules 已安装"
assert_exists "$TARGET/.claude/rules/security.md" "common/security.md 已安装"
assert_not_exists "$TARGET/.claude/agents" "未安装 agents (未选择)"
assert_not_exists "$TARGET/.claude/commands" "未安装 commands (未选择)"
assert_not_exists "$TARGET/.claude/settings.json" "未安装 hooks (未选择)"

# ============================================================================
echo -e "\n${BOLD}${CYAN}=== 测试 4: Dry Run 模式 ===${NC}\n"
# ============================================================================

TARGET="$TEST_BASE/test-run-4"
rm -rf "$TARGET" && mkdir -p "$TARGET"

bash "$MIGRATE" \
  --dry-run --force --repo "$REPO_DIR" --scope project \
  --lang typescript \
  --component agents --component rules \
  "$TARGET" >/dev/null 2>&1

assert_not_exists "$TARGET/.claude" "dry-run 未创建 .claude 目录"
assert_not_exists "$TARGET/.claude.json" "dry-run 未创建 .claude.json"

# ============================================================================
echo -e "\n${BOLD}${CYAN}=== 测试 5: MCP 配置 - 已有 .mcp.json ===${NC}\n"
# ============================================================================

TARGET="$TEST_BASE/test-run-5"
rm -rf "$TARGET" && mkdir -p "$TARGET"
echo '{"mcpServers":{"my-server":{"url":"http://localhost:3000"}}}' > "$TARGET/.mcp.json"

bash "$MIGRATE" \
  --force --repo "$REPO_DIR" --scope project \
  --component mcp-configs \
  "$TARGET" >/dev/null 2>&1

assert_contains "$TARGET/.mcp.json" "my-server" "原有 .mcp.json 中的服务器被保留"
assert_contains "$TARGET/.mcp.json" "mcpServers" ".mcp.json 包含 mcpServers 键"

# ============================================================================
echo -e "\n${BOLD}${CYAN}=== 测试 6: zh-CN Locale - 中文内容 + 英文回退 ===${NC}\n"
# ============================================================================

TARGET="$TEST_BASE/test-run-6"
rm -rf "$TARGET" && mkdir -p "$TARGET"

bash "$MIGRATE" \
  --force --repo "$REPO_DIR" --scope project \
  --locale zh-CN \
  --lang typescript \
  --component agents --component commands --component rules --component contexts \
  "$TARGET" >/dev/null 2>&1

# 验证中文内容被安装
assert_exists "$TARGET/.claude/agents/planner.md" "zh-CN agents/planner.md 已安装"
assert_exists "$TARGET/.claude/commands/plan.md" "zh-CN commands/plan.md 已安装"
assert_exists "$TARGET/.claude/contexts/dev.md" "zh-CN contexts/dev.md 已安装"
assert_exists "$TARGET/.claude/rules/coding-style.md" "zh-CN rules 已安装"

# 验证中文内容确实是中文（检查 planner.md 包含中文字符）
if grep -q '规划' "$TARGET/.claude/agents/planner.md" 2>/dev/null || \
   grep -q '计划' "$TARGET/.claude/agents/planner.md" 2>/dev/null || \
   grep -q '实现' "$TARGET/.claude/agents/planner.md" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC} agents/planner.md 包含中文内容"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} agents/planner.md 未包含中文内容"
  FAIL=$((FAIL + 1))
fi

# 验证英文回退：zh-CN 缺少的 commands 应从英文补齐
# pm2.md 在 docs/zh-CN/commands/ 中不存在，应从英文回退
assert_exists "$TARGET/.claude/commands/pm2.md" "英文回退: commands/pm2.md 已补齐"

# 验证总文件数 >= 英文原版（回退保证不丢文件）
EN_CMD_COUNT=$(find "$REPO_DIR/commands" -type f | wc -l | tr -d ' ')
ZH_CMD_COUNT=$(find "$TARGET/.claude/commands" -type f | wc -l | tr -d ' ')
if [[ "$ZH_CMD_COUNT" -ge "$EN_CMD_COUNT" ]]; then
  echo -e "  ${GREEN}PASS${NC} commands 文件数完整 ($ZH_CMD_COUNT >= $EN_CMD_COUNT)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC} commands 文件数不足 ($ZH_CMD_COUNT < $EN_CMD_COUNT)"
  FAIL=$((FAIL + 1))
fi

# ============================================================================
# 汇总
# ============================================================================

echo ""
echo -e "${BOLD}${CYAN}=== 测试结果 ===${NC}"
echo ""
echo -e "  ${GREEN}通过: $PASS${NC}"
echo -e "  ${RED}失败: $FAIL${NC}"
echo ""

# 清理测试目录
rm -rf "$TEST_BASE"/test-run-*

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "${RED}存在失败的测试!${NC}"
  exit 1
else
  echo -e "${GREEN}所有测试通过!${NC}"
  exit 0
fi

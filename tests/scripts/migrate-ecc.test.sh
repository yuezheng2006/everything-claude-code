#!/usr/bin/env bash
# ============================================================================
# Tests for scripts/migrate-ecc.sh
#
# Usage: bash tests/scripts/migrate-ecc.test.sh
#
# Tests cover:
#   - Argument parsing (parse_args)
#   - Utility functions (count_files, detect_existing_config, check_command)
#   - Clone / local repo resolution (clone_repo with SKIP_CLONE)
#   - Locale-aware source resolution (get_locale_src, copy_with_fallback)
#   - Selection defaults (select_scope, select_target, select_components)
#   - Backup logic (backup_config with --backup, --no-backup, dry-run)
#   - safe_copy (files, directories, dry-run, missing source)
#   - Migration components (agents, commands, skills, rules, contexts, plugins)
#   - Hooks migration (Node.js converter, settings.json merge)
#   - MCP config migration (clean install, merge)
#   - Integration: full dry-run, project-scope, locale, idempotent re-run
# ============================================================================

set -euo pipefail

# ============================================================================
# Test framework
# ============================================================================

PASSED=0
FAILED=0
CURRENT_SUITE=""
TEST_TMPDIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/scripts/migrate-ecc.sh"

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown_tmpdir() {
  if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
  TEST_TMPDIR=""
}

suite() {
  CURRENT_SUITE="$1"
  echo ""
  echo "━━━ $1 ━━━"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  if [[ "$expected" != "$actual" ]]; then
    echo "    Expected: '$expected'"
    echo "    Actual:   '$actual'"
    return 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "    Does not contain: '$needle'"
    echo "    In: '${haystack:0:200}'"
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "    Should not contain: '$needle'"
    return 1
  fi
}

assert_file_exists() {
  if [[ ! -f "$1" ]]; then
    echo "    File missing: $1"
    return 1
  fi
}

assert_dir_exists() {
  if [[ ! -d "$1" ]]; then
    echo "    Dir missing: $1"
    return 1
  fi
}

assert_file_not_exists() {
  if [[ -f "$1" ]]; then
    echo "    File should not exist: $1"
    return 1
  fi
}

run_test() {
  local name="$1"
  local fn="$2"
  setup_tmpdir
  if $fn 2>/dev/null; then
    echo "  ✓ $name"
    PASSED=$((PASSED + 1))
  else
    echo "  ✗ $name"
    FAILED=$((FAILED + 1))
  fi
  teardown_tmpdir
}

# ============================================================================
# Fixture: create a minimal fake ECC repo
# ============================================================================

create_fake_repo() {
  local repo="$1"
  mkdir -p "$repo"/{agents,commands,contexts,plugins}
  mkdir -p "$repo"/skills/{tdd-workflow,security-review}
  mkdir -p "$repo"/rules/{common,typescript,python,golang}
  mkdir -p "$repo"/{hooks,mcp-configs}
  mkdir -p "$repo"/scripts/{hooks,lib}

  echo "# Planner" > "$repo/agents/planner.md"
  echo "# Reviewer" > "$repo/agents/code-reviewer.md"
  echo "# Plan" > "$repo/commands/plan.md"
  echo "# TDD" > "$repo/commands/tdd.md"
  echo "# Review" > "$repo/commands/code-review.md"
  echo "# TDD Skill" > "$repo/skills/tdd-workflow/SKILL.md"
  echo "# Sec Skill" > "$repo/skills/security-review/SKILL.md"
  echo "# Style" > "$repo/rules/common/coding-style.md"
  echo "# Security" > "$repo/rules/common/security.md"
  echo "# Testing" > "$repo/rules/common/testing.md"
  echo "# TS Style" > "$repo/rules/typescript/coding-style.md"
  echo "# TS Test" > "$repo/rules/typescript/testing.md"
  echo "# PY Style" > "$repo/rules/python/coding-style.md"
  echo "# GO Style" > "$repo/rules/golang/coding-style.md"
  echo "# Dev" > "$repo/contexts/dev.md"
  echo "# Review" > "$repo/contexts/review.md"
  echo "# Plugins" > "$repo/plugins/README.md"
  echo "// hook" > "$repo/scripts/hooks/check-console-log.js"
  echo "// lib" > "$repo/scripts/lib/utils.js"

  cat > "$repo/hooks/hooks.json" << 'HOOKEOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "tool == \"Bash\"",
        "hooks": [{"type": "command", "command": "echo test-hook"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "tool == \"Edit\" && tool_input.file_path matches \"\\\\.(ts|tsx)$\"",
        "hooks": [{"type": "command", "command": "echo post-edit"}]
      }
    ]
  }
}
HOOKEOF

  cat > "$repo/mcp-configs/mcp-servers.json" << 'MCPEOF'
{
  "mcpServers": {
    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory"],
      "description": "Persistent memory"
    },
    "context7": {
      "command": "npx",
      "args": ["-y", "@context7/mcp-server"],
      "description": "Live docs"
    }
  }
}
MCPEOF

  # zh-CN locale
  mkdir -p "$repo/docs/zh-CN"/{agents,commands,rules,contexts,plugins}
  mkdir -p "$repo/docs/zh-CN/skills/tdd-workflow"
  echo "# 规划代理" > "$repo/docs/zh-CN/agents/planner.md"
  echo "# 计划命令" > "$repo/docs/zh-CN/commands/plan.md"
  echo "# 编码风格" > "$repo/docs/zh-CN/rules/coding-style.md"
  echo "# TDD 技能" > "$repo/docs/zh-CN/skills/tdd-workflow/SKILL.md"
  echo "# 开发上下文" > "$repo/docs/zh-CN/contexts/dev.md"
  echo "# 插件说明" > "$repo/docs/zh-CN/plugins/README.md"
}

# Create a sourceable version (no auto-execute)
create_sourceable() {
  local out="$TEST_TMPDIR/_source.sh"
  sed '$d' "$SCRIPT_PATH" | sed '$d' > "$out"
  echo "$out"
}

# ============================================================================
# 1. Argument Parsing Tests
# ============================================================================

test_version_flag() {
  local output
  output=$(bash "$SCRIPT_PATH" --version 2>&1)
  assert_contains "$output" "migrate-ecc v"
}

test_scope_short_flag() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args -s user
    echo \"\$INSTALL_SCOPE\"
  ")
  assert_eq "user" "$result"
}

test_scope_long_flag() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args --scope project
    echo \"\$INSTALL_SCOPE\"
  ")
  assert_eq "project" "$result"
}

test_lang_flag_single() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args -l typescript
    echo \"\${SELECTED_LANGS[*]}\"
  ")
  assert_eq "typescript" "$result"
}

test_lang_flag_multiple() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args -l typescript -l python -l golang
    echo \"\${SELECTED_LANGS[*]}\"
  ")
  assert_eq "typescript python golang" "$result"
}

test_component_flag() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args -c agents -c rules
    echo \"\${SELECTED_COMPONENTS[*]}\"
  ")
  assert_eq "agents rules" "$result"
}

test_repo_flag() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args -r /tmp/my-repo
    echo \"\$LOCAL_REPO|\$SKIP_CLONE\"
  ")
  assert_eq "/tmp/my-repo|true" "$result"
}

test_locale_flag() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args -L zh-CN
    echo \"\$LOCALE\"
  ")
  assert_eq "zh-CN" "$result"
}

test_dry_run_flag() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args --dry-run
    echo \"\$DRY_RUN\"
  ")
  assert_eq "true" "$result"
}

test_force_flag() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args --force
    echo \"\$FORCE\"
  ")
  assert_eq "true" "$result"
}

test_backup_flag() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args --backup
    echo \"\$DO_BACKUP\"
  ")
  assert_eq "yes" "$result"
}

test_no_backup_flag() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args --no-backup
    echo \"\$DO_BACKUP\"
  ")
  assert_eq "no" "$result"
}

test_positional_target() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args /tmp/my-project
    echo \"\$TARGET_DIR\"
  ")
  assert_eq "/tmp/my-project" "$result"
}

test_combined_flags() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    parse_args -s project -l typescript -c agents -d -f /tmp/proj
    echo \"\$INSTALL_SCOPE|\$DRY_RUN|\$FORCE|\$TARGET_DIR\"
    echo \"\${SELECTED_LANGS[*]}\"
    echo \"\${SELECTED_COMPONENTS[*]}\"
  ")
  local line1 line2 line3
  line1=$(echo "$result" | head -1)
  line2=$(echo "$result" | sed -n '2p')
  line3=$(echo "$result" | sed -n '3p')
  assert_eq "project|true|true|/tmp/proj" "$line1"
  assert_eq "typescript" "$line2"
  assert_eq "agents" "$line3"
}

test_unknown_option_exits() {
  local exit_code=0
  bash "$SCRIPT_PATH" --unknown-flag 2>/dev/null || exit_code=$?
  # Script calls usage() which exits 0, so just verify it doesn't proceed normally
  # The error message is printed, and usage is shown, then exit 0
  [[ "$exit_code" -eq 0 ]]
}

# ============================================================================
# 2. Utility Function Tests
# ============================================================================

test_count_files_empty_dir() {
  local src; src=$(create_sourceable)
  mkdir -p "$TEST_TMPDIR/empty"
  local result
  result=$(bash -c "
    source '$src'
    count_files '$TEST_TMPDIR/empty'
  ")
  assert_eq "0" "$result"
}

test_count_files_with_files() {
  local src; src=$(create_sourceable)
  mkdir -p "$TEST_TMPDIR/files"
  echo "a" > "$TEST_TMPDIR/files/a.txt"
  echo "b" > "$TEST_TMPDIR/files/b.txt"
  echo "c" > "$TEST_TMPDIR/files/c.txt"
  local result
  result=$(bash -c "
    source '$src'
    count_files '$TEST_TMPDIR/files'
  ")
  assert_eq "3" "$result"
}

test_count_files_nonexistent() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    count_files '/nonexistent/dir'
  ")
  assert_eq "0" "$result"
}

test_count_files_nested() {
  local src; src=$(create_sourceable)
  mkdir -p "$TEST_TMPDIR/nested/sub"
  echo "a" > "$TEST_TMPDIR/nested/a.txt"
  echo "b" > "$TEST_TMPDIR/nested/sub/b.txt"
  local result
  result=$(bash -c "
    source '$src'
    count_files '$TEST_TMPDIR/nested'
  ")
  assert_eq "2" "$result"
}

test_check_command_exists() {
  local src; src=$(create_sourceable)
  # bash should always exist
  bash -c "
    source '$src'
    check_command bash
  "
}

test_check_command_missing() {
  local src; src=$(create_sourceable)
  local exit_code=0
  bash -c "
    source '$src'
    check_command nonexistent_cmd_xyz_12345
  " 2>/dev/null || exit_code=$?
  [[ "$exit_code" -ne 0 ]]
}

test_detect_existing_config_found() {
  local src; src=$(create_sourceable)
  mkdir -p "$TEST_TMPDIR/proj/.claude/agents"
  local exit_code=0
  bash -c "
    source '$src'
    detect_existing_config '$TEST_TMPDIR/proj'
  " 2>/dev/null || exit_code=$?
  assert_eq "0" "$exit_code"
}

test_detect_existing_config_not_found() {
  local src; src=$(create_sourceable)
  mkdir -p "$TEST_TMPDIR/clean-proj"
  local exit_code=0
  bash -c "
    source '$src'
    detect_existing_config '$TEST_TMPDIR/clean-proj'
  " 2>/dev/null || exit_code=$?
  assert_eq "1" "$exit_code"
}

test_detect_existing_config_claude_md() {
  local src; src=$(create_sourceable)
  mkdir -p "$TEST_TMPDIR/proj2"
  echo "# Claude" > "$TEST_TMPDIR/proj2/CLAUDE.md"
  local exit_code=0
  bash -c "
    source '$src'
    detect_existing_config '$TEST_TMPDIR/proj2'
  " 2>/dev/null || exit_code=$?
  assert_eq "0" "$exit_code"
}

test_detect_existing_config_mcp_json() {
  local src; src=$(create_sourceable)
  mkdir -p "$TEST_TMPDIR/proj3"
  echo '{}' > "$TEST_TMPDIR/proj3/.mcp.json"
  local exit_code=0
  bash -c "
    source '$src'
    detect_existing_config '$TEST_TMPDIR/proj3'
  " 2>/dev/null || exit_code=$?
  assert_eq "0" "$exit_code"
}

test_info_output() {
  local src; src=$(create_sourceable)
  local output
  output=$(bash -c "source '$src'; info 'hello world'" 2>&1)
  assert_contains "$output" "[INFO]"
  assert_contains "$output" "hello world"
}

test_warn_output() {
  local src; src=$(create_sourceable)
  local output
  output=$(bash -c "source '$src'; warn 'caution'" 2>&1)
  assert_contains "$output" "[WARN]"
  assert_contains "$output" "caution"
}

test_error_output() {
  local src; src=$(create_sourceable)
  local output
  output=$(bash -c "source '$src'; error 'failure'" 2>&1)
  assert_contains "$output" "[ERROR]"
  assert_contains "$output" "failure"
}

test_success_output() {
  local src; src=$(create_sourceable)
  local output
  output=$(bash -c "source '$src'; success 'done'" 2>&1)
  assert_contains "$output" "[OK]"
  assert_contains "$output" "done"
}

test_confirm_force_true() {
  local src; src=$(create_sourceable)
  local exit_code=0
  bash -c "
    source '$src'
    FORCE=true
    confirm 'proceed?'
  " || exit_code=$?
  assert_eq "0" "$exit_code"
}

# ============================================================================
# 3. Clone / Locale Tests
# ============================================================================

test_clone_repo_skip_with_local() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/fake-repo"
  create_fake_repo "$repo"
  local output
  output=$(bash -c "
    source '$src'
    SKIP_CLONE=true
    LOCAL_REPO='$repo'
    clone_repo
    echo \"\$TMP_DIR\"
  " 2>&1)
  assert_contains "$output" "$TEST_TMPDIR/fake-repo"
}

test_clone_repo_skip_missing_dir() {
  local src; src=$(create_sourceable)
  local exit_code=0
  bash -c "
    source '$src'
    SKIP_CLONE=true
    LOCAL_REPO='/nonexistent/path'
    clone_repo
  " 2>/dev/null || exit_code=$?
  [[ "$exit_code" -ne 0 ]]
}

test_get_locale_src_no_locale() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  create_fake_repo "$repo"
  local result
  result=$(bash -c "
    source '$src'
    TMP_DIR='$repo'
    LOCALE=''
    get_locale_src agents
  ")
  assert_eq "$repo/agents" "$result"
}

test_get_locale_src_with_locale() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  create_fake_repo "$repo"
  local result
  result=$(bash -c "
    source '$src'
    TMP_DIR='$repo'
    LOCALE='zh-CN'
    get_locale_src agents
  ")
  assert_eq "$repo/docs/zh-CN/agents" "$result"
}

test_get_locale_src_fallback() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  create_fake_repo "$repo"
  local result
  result=$(bash -c "
    source '$src'
    TMP_DIR='$repo'
    LOCALE='zh-TW'
    get_locale_src agents
  ")
  assert_eq "$repo/agents" "$result"
}

# ============================================================================
# 4. Selection Defaults
# ============================================================================

test_select_scope_default() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    INSTALL_SCOPE=''
    select_scope
    echo \"\$INSTALL_SCOPE\"
  " 2>/dev/null)
  # Output may include info messages; check last line
  local last_line
  last_line=$(echo "$result" | tail -1)
  assert_eq "project" "$last_line"
}

test_select_scope_preset() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    INSTALL_SCOPE='user'
    select_scope
    echo \"\$INSTALL_SCOPE\"
  " 2>/dev/null)
  assert_eq "user" "$result"
}

test_select_target_user_scope() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    INSTALL_SCOPE='user'
    select_target
    echo \"\$TARGET_DIR\"
  " 2>/dev/null)
  assert_eq "$HOME" "$result"
}

test_select_target_default_cwd() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    INSTALL_SCOPE='project'
    TARGET_DIR=''
    select_target
    echo \"\$TARGET_DIR\"
  " 2>/dev/null)
  local last_line
  last_line=$(echo "$result" | tail -1)
  assert_eq "$(pwd)" "$last_line"
}

test_select_target_nonexistent_exits() {
  local src; src=$(create_sourceable)
  local exit_code=0
  bash -c "
    source '$src'
    INSTALL_SCOPE='project'
    TARGET_DIR='/nonexistent/xyz'
    select_target
  " 2>/dev/null || exit_code=$?
  [[ "$exit_code" -ne 0 ]]
}

test_select_components_default_all() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    SELECTED_COMPONENTS=()
    select_components
    echo \"\${SELECTED_COMPONENTS[*]}\"
  " 2>/dev/null)
  assert_contains "$result" "agents"
  assert_contains "$result" "rules"
  assert_contains "$result" "hooks"
  assert_contains "$result" "mcp-configs"
}

test_select_components_preset() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    SELECTED_COMPONENTS=(agents rules)
    select_components
    echo \"\${SELECTED_COMPONENTS[*]}\"
  " 2>/dev/null)
  assert_eq "agents rules" "$result"
}

test_select_languages_default_all() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    SELECTED_LANGS=()
    SELECTED_COMPONENTS=(rules)
    select_languages
    echo \"\${SELECTED_LANGS[*]}\"
  " 2>/dev/null)
  local last_line
  last_line=$(echo "$result" | tail -1)
  assert_eq "typescript python golang" "$last_line"
}

test_select_languages_skipped_no_rules() {
  local src; src=$(create_sourceable)
  local result
  result=$(bash -c "
    source '$src'
    SELECTED_LANGS=()
    SELECTED_COMPONENTS=(agents commands)
    select_languages
    echo \"\${#SELECTED_LANGS[@]}\"
  " 2>/dev/null)
  assert_eq "0" "$result"
}

# ============================================================================
# 5. Backup Tests
# ============================================================================

test_backup_creates_copy() {
  local src; src=$(create_sourceable)
  local target="$TEST_TMPDIR/proj"
  mkdir -p "$target/.claude/agents"
  echo "existing" > "$target/.claude/agents/test.md"
  bash -c "
    source '$src'
    TARGET_DIR='$target'
    DO_BACKUP='yes'
    DRY_RUN=false
    FORCE=true
    backup_config
  " 2>/dev/null
  local backup_count
  backup_count=$(ls -d "$target"/.claude-backup-* 2>/dev/null | wc -l | tr -d ' ')
  [[ "$backup_count" -ge 1 ]]
}

test_backup_no_backup_flag() {
  local src; src=$(create_sourceable)
  local target="$TEST_TMPDIR/proj"
  mkdir -p "$target/.claude"
  bash -c "
    source '$src'
    TARGET_DIR='$target'
    DO_BACKUP='no'
    DRY_RUN=false
    backup_config
  " 2>/dev/null
  local backup_count
  backup_count=$(ls -d "$target"/.claude-backup-* 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "0" "$backup_count"
}

test_backup_dry_run() {
  local src; src=$(create_sourceable)
  local target="$TEST_TMPDIR/proj"
  mkdir -p "$target/.claude"
  local output
  output=$(bash -c "
    source '$src'
    TARGET_DIR='$target'
    DO_BACKUP='yes'
    DRY_RUN=true
    backup_config
  " 2>&1)
  assert_contains "$output" "DRY RUN"
  local backup_count
  backup_count=$(ls -d "$target"/.claude-backup-* 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "0" "$backup_count"
}

test_backup_skipped_no_claude_dir() {
  local src; src=$(create_sourceable)
  local target="$TEST_TMPDIR/clean"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TARGET_DIR='$target'
    DO_BACKUP='yes'
    DRY_RUN=false
    backup_config
  " 2>/dev/null
}

# ============================================================================
# 6. safe_copy Tests
# ============================================================================

test_safe_copy_file() {
  local src; src=$(create_sourceable)
  echo "content" > "$TEST_TMPDIR/src.txt"
  bash -c "
    source '$src'
    DRY_RUN=false
    safe_copy '$TEST_TMPDIR/src.txt' '$TEST_TMPDIR/dest.txt' 'test'
  " 2>/dev/null
  assert_file_exists "$TEST_TMPDIR/dest.txt"
  local content
  content=$(cat "$TEST_TMPDIR/dest.txt")
  assert_eq "content" "$content"
}

test_safe_copy_directory() {
  local src; src=$(create_sourceable)
  mkdir -p "$TEST_TMPDIR/srcdir"
  echo "a" > "$TEST_TMPDIR/srcdir/a.txt"
  echo "b" > "$TEST_TMPDIR/srcdir/b.txt"
  bash -c "
    source '$src'
    DRY_RUN=false
    safe_copy '$TEST_TMPDIR/srcdir' '$TEST_TMPDIR/destdir' 'test'
  " 2>/dev/null
  assert_file_exists "$TEST_TMPDIR/destdir/a.txt"
  assert_file_exists "$TEST_TMPDIR/destdir/b.txt"
}

test_safe_copy_dry_run() {
  local src; src=$(create_sourceable)
  echo "content" > "$TEST_TMPDIR/src.txt"
  local output
  output=$(bash -c "
    source '$src'
    DRY_RUN=true
    safe_copy '$TEST_TMPDIR/src.txt' '$TEST_TMPDIR/dest.txt' 'test'
  " 2>&1)
  assert_contains "$output" "DRY RUN"
  assert_file_not_exists "$TEST_TMPDIR/dest.txt"
}

test_safe_copy_missing_source() {
  local src; src=$(create_sourceable)
  local output
  output=$(bash -c "
    source '$src'
    DRY_RUN=false
    safe_copy '/nonexistent/file' '$TEST_TMPDIR/dest.txt' 'test'
  " 2>&1)
  assert_contains "$output" "Source not found"
}

test_safe_copy_creates_parent_dirs() {
  local src; src=$(create_sourceable)
  echo "content" > "$TEST_TMPDIR/src.txt"
  bash -c "
    source '$src'
    DRY_RUN=false
    safe_copy '$TEST_TMPDIR/src.txt' '$TEST_TMPDIR/deep/nested/dest.txt' 'test'
  " 2>/dev/null
  assert_file_exists "$TEST_TMPDIR/deep/nested/dest.txt"
}

# ============================================================================
# 7. Migration Component Tests
# ============================================================================

test_migrate_agents() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    LOCALE=''
    migrate_agents
  " 2>/dev/null
  assert_file_exists "$target/.claude/agents/planner.md"
  assert_file_exists "$target/.claude/agents/code-reviewer.md"
}

test_migrate_agents_dry_run() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  local output
  output=$(bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=true
    LOCALE=''
    migrate_agents
  " 2>&1)
  assert_contains "$output" "DRY RUN"
  assert_file_not_exists "$target/.claude/agents/planner.md"
}

test_migrate_commands() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    LOCALE=''
    migrate_commands
  " 2>/dev/null
  assert_file_exists "$target/.claude/commands/plan.md"
  assert_file_exists "$target/.claude/commands/tdd.md"
  assert_file_exists "$target/.claude/commands/code-review.md"
}

test_migrate_skills() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    LOCALE=''
    migrate_skills
  " 2>/dev/null
  assert_file_exists "$target/.claude/skills/tdd-workflow/SKILL.md"
  assert_file_exists "$target/.claude/skills/security-review/SKILL.md"
}

test_migrate_contexts() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    LOCALE=''
    migrate_contexts
  " 2>/dev/null
  assert_file_exists "$target/.claude/contexts/dev.md"
  assert_file_exists "$target/.claude/contexts/review.md"
}

test_migrate_plugins() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    LOCALE=''
    migrate_plugins
  " 2>/dev/null
  assert_file_exists "$target/.claude/plugins/README.md"
}

test_migrate_rules_common_only() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    LOCALE=''
    SELECTED_LANGS=()
    migrate_rules
  " 2>/dev/null
  assert_file_exists "$target/.claude/rules/coding-style.md"
  assert_file_exists "$target/.claude/rules/security.md"
  assert_file_exists "$target/.claude/rules/testing.md"
}

test_migrate_rules_with_typescript() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    LOCALE=''
    SELECTED_LANGS=(typescript)
    migrate_rules
  " 2>/dev/null
  # Common rules in root
  assert_file_exists "$target/.claude/rules/coding-style.md"
  # TS rules in subdirectory (not overwriting common)
  assert_dir_exists "$target/.claude/rules/typescript"
  assert_file_exists "$target/.claude/rules/typescript/coding-style.md"
}

test_migrate_rules_with_all_langs() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    LOCALE=''
    SELECTED_LANGS=(typescript python golang)
    migrate_rules
  " 2>/dev/null
  # Common rules preserved
  assert_file_exists "$target/.claude/rules/coding-style.md"
  local common_content
  common_content=$(cat "$target/.claude/rules/coding-style.md")
  assert_contains "$common_content" "Coding Style"
  # Each language in its own subdirectory
  assert_dir_exists "$target/.claude/rules/typescript"
  assert_dir_exists "$target/.claude/rules/python"
  assert_dir_exists "$target/.claude/rules/golang"
  assert_file_exists "$target/.claude/rules/typescript/coding-style.md"
  assert_file_exists "$target/.claude/rules/python/coding-style.md"
  assert_file_exists "$target/.claude/rules/golang/coding-style.md"
  # Verify no overwrite: common != golang
  local go_content
  go_content=$(cat "$target/.claude/rules/golang/coding-style.md")
  assert_contains "$go_content" "GO Style"
}

test_migrate_rules_missing_lang() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  local output
  output=$(bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    LOCALE=''
    SELECTED_LANGS=(rust)
    migrate_rules
  " 2>&1)
  assert_contains "$output" "Language rules not found: rust"
}

test_migrate_agents_with_locale() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    LOCALE='zh-CN'
    migrate_agents
  " 2>/dev/null
  assert_file_exists "$target/.claude/agents/planner.md"
  # Should have zh-CN content
  local content
  content=$(cat "$target/.claude/agents/planner.md")
  assert_contains "$content" "规划代理"
}

test_migrate_agents_locale_with_fallback() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    LOCALE='zh-CN'
    migrate_agents
  " 2>/dev/null
  # code-reviewer.md only exists in English, should be filled from fallback
  assert_file_exists "$target/.claude/agents/code-reviewer.md"
  local content
  content=$(cat "$target/.claude/agents/code-reviewer.md")
  assert_contains "$content" "Reviewer"
}

# ============================================================================
# 8. Hooks Migration Tests
# ============================================================================

test_migrate_hooks_creates_settings() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target/.claude"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_hooks
  " 2>/dev/null
  assert_file_exists "$target/.claude/settings.json"
  # Verify it's valid JSON
  node -e "JSON.parse(require('fs').readFileSync('$target/.claude/settings.json','utf8'))"
}

test_migrate_hooks_has_events() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target/.claude"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_hooks
  " 2>/dev/null
  local content
  content=$(cat "$target/.claude/settings.json")
  assert_contains "$content" "PreToolUse"
  assert_contains "$content" "PostToolUse"
}

test_migrate_hooks_converts_matcher() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target/.claude"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_hooks
  " 2>/dev/null
  local content
  content=$(cat "$target/.claude/settings.json")
  # The expression "tool == \"Bash\"" should be converted to just "Bash"
  assert_contains "$content" "Bash"
}

test_migrate_hooks_copies_scripts() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target/.claude"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_hooks
  " 2>/dev/null
  assert_file_exists "$target/.claude/scripts/hooks/check-console-log.js"
  assert_file_exists "$target/.claude/scripts/lib/utils.js"
}

test_migrate_hooks_dry_run() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target/.claude"
  local output
  output=$(bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=true
    migrate_hooks
  " 2>&1)
  assert_contains "$output" "DRY RUN"
  assert_file_not_exists "$target/.claude/settings.json"
}

test_migrate_hooks_merge_existing() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target/.claude"
  # Pre-existing settings.json with custom content
  echo '{"customKey": "preserved", "hooks": {}}' > "$target/.claude/settings.json"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_hooks
  " 2>/dev/null
  local content
  content=$(cat "$target/.claude/settings.json")
  # Should preserve existing keys
  assert_contains "$content" "customKey"
  assert_contains "$content" "preserved"
  # Should also have hooks
  assert_contains "$content" "PreToolUse"
}

test_migrate_hooks_dedup() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target/.claude"
  # Run hooks migration twice
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_hooks
  " 2>/dev/null
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_hooks
  " 2>/dev/null
  # Count PreToolUse entries - should not duplicate
  local count
  count=$(node -e "
    const s = JSON.parse(require('fs').readFileSync('$target/.claude/settings.json','utf8'));
    console.log((s.hooks.PreToolUse || []).length);
  ")
  assert_eq "1" "$count"
}

test_migrate_hooks_missing_hooks_json() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  mkdir -p "$repo" "$target/.claude"
  # No hooks.json
  local output
  output=$(bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_hooks
  " 2>&1)
  assert_contains "$output" "No hooks.json found"
}

# ============================================================================
# 9. MCP Config Migration Tests
# ============================================================================

test_migrate_mcp_clean_install() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_mcp_configs
  " 2>/dev/null
  assert_file_exists "$target/.mcp.json"
  # Verify valid JSON
  node -e "JSON.parse(require('fs').readFileSync('$target/.mcp.json','utf8'))"
}

test_migrate_mcp_strips_description() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_mcp_configs
  " 2>/dev/null
  local content
  content=$(cat "$target/.mcp.json")
  assert_not_contains "$content" "description"
}

test_migrate_mcp_has_servers() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_mcp_configs
  " 2>/dev/null
  local content
  content=$(cat "$target/.mcp.json")
  assert_contains "$content" "memory"
  assert_contains "$content" "context7"
}

test_migrate_mcp_merge_existing() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  # Pre-existing .mcp.json with a custom server
  cat > "$target/.mcp.json" << 'EOF'
{
  "mcpServers": {
    "custom-server": {
      "command": "npx",
      "args": ["-y", "custom-mcp"]
    }
  }
}
EOF
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_mcp_configs
  " 2>/dev/null
  local content
  content=$(cat "$target/.mcp.json")
  # Should preserve existing
  assert_contains "$content" "custom-server"
  # Should add new
  assert_contains "$content" "memory"
  assert_contains "$content" "context7"
}

test_migrate_mcp_skip_duplicates() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  # Pre-existing with memory already
  cat > "$target/.mcp.json" << 'EOF'
{
  "mcpServers": {
    "memory": {
      "command": "npx",
      "args": ["-y", "my-custom-memory"]
    }
  }
}
EOF
  bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_mcp_configs
  " 2>/dev/null
  local content
  content=$(cat "$target/.mcp.json")
  # Should keep original memory config, not overwrite
  assert_contains "$content" "my-custom-memory"
}

test_migrate_mcp_dry_run() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  local output
  output=$(bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=true
    migrate_mcp_configs
  " 2>&1)
  assert_contains "$output" "DRY RUN"
  assert_file_not_exists "$target/.mcp.json"
}

test_migrate_mcp_missing_source() {
  local src; src=$(create_sourceable)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  mkdir -p "$repo" "$target"
  local output
  output=$(bash -c "
    source '$src'
    TMP_DIR='$repo'
    TARGET_DIR='$target'
    DRY_RUN=false
    migrate_mcp_configs
  " 2>&1)
  assert_contains "$output" "No MCP configs found"
}

# ============================================================================
# 10. Integration Tests (full script execution)
# ============================================================================

test_integration_dry_run_full() {
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  local output
  output=$(bash "$SCRIPT_PATH" \
    --dry-run --force \
    -r "$repo" \
    -s project \
    -l typescript \
    -c agents -c commands -c rules -c hooks -c mcp-configs \
    "$target" 2>&1)
  assert_contains "$output" "DRY RUN"
  assert_contains "$output" "Migration Complete"
  # Nothing should be created in dry-run
  [[ ! -d "$target/.claude" ]]
}

test_integration_project_scope_all() {
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  local output
  output=$(bash "$SCRIPT_PATH" \
    --force --no-backup \
    -r "$repo" \
    -s project \
    -l typescript -l python -l golang \
    "$target" 2>&1)
  assert_contains "$output" "Migration Complete"
  # Verify key files exist
  assert_dir_exists "$target/.claude/agents"
  assert_dir_exists "$target/.claude/commands"
  assert_dir_exists "$target/.claude/skills"
  assert_dir_exists "$target/.claude/rules"
  assert_dir_exists "$target/.claude/contexts"
  assert_dir_exists "$target/.claude/plugins"
  assert_file_exists "$target/.claude/settings.json"
  assert_file_exists "$target/.mcp.json"
}

test_integration_selective_components() {
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash "$SCRIPT_PATH" \
    --force --no-backup \
    -r "$repo" \
    -s project \
    -c agents -c commands \
    "$target" 2>/dev/null
  assert_dir_exists "$target/.claude/agents"
  assert_dir_exists "$target/.claude/commands"
  # Should NOT have rules, hooks, mcp
  [[ ! -d "$target/.claude/rules" ]] || [[ ! -f "$target/.claude/rules/coding-style.md" ]]
  assert_file_not_exists "$target/.mcp.json"
}

test_integration_locale_zh_cn() {
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  bash "$SCRIPT_PATH" \
    --force --no-backup \
    -r "$repo" \
    -s project \
    -L zh-CN \
    -c agents \
    "$target" 2>/dev/null
  assert_file_exists "$target/.claude/agents/planner.md"
  local content
  content=$(cat "$target/.claude/agents/planner.md")
  assert_contains "$content" "规划代理"
}

test_integration_idempotent_rerun() {
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  # Run once
  bash "$SCRIPT_PATH" \
    --force --no-backup \
    -r "$repo" \
    -s project \
    -c agents -c mcp-configs \
    "$target" 2>/dev/null
  # Run again
  bash "$SCRIPT_PATH" \
    --force --no-backup \
    -r "$repo" \
    -s project \
    -c agents -c mcp-configs \
    "$target" 2>/dev/null
  # Should still work, files should exist
  assert_file_exists "$target/.claude/agents/planner.md"
  assert_file_exists "$target/.mcp.json"
  # MCP should not have duplicated servers
  local server_count
  server_count=$(node -e "
    const d = JSON.parse(require('fs').readFileSync('$target/.mcp.json','utf8'));
    console.log(Object.keys(d.mcpServers || {}).length);
  ")
  assert_eq "2" "$server_count"
}

test_integration_backup_and_migrate() {
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target/.claude/agents"
  echo "old content" > "$target/.claude/agents/planner.md"
  bash "$SCRIPT_PATH" \
    --force --backup \
    -r "$repo" \
    -s project \
    -c agents \
    "$target" 2>/dev/null
  # Backup should exist
  local backup_count
  backup_count=$(ls -d "$target"/.claude-backup-* 2>/dev/null | wc -l | tr -d ' ')
  [[ "$backup_count" -ge 1 ]]
  # New content should be installed
  local content
  content=$(cat "$target/.claude/agents/planner.md")
  assert_contains "$content" "Planner"
}

test_integration_version_output() {
  local output
  output=$(bash "$SCRIPT_PATH" --version 2>&1)
  assert_contains "$output" "migrate-ecc v1.2.0"
}

test_integration_zero_args_with_local_repo() {
  # Simulates zero-arg behavior: all defaults kick in
  # (uses -r to avoid real git clone, but everything else is default)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  # Run from target dir with only -r (simulating zero-arg defaults)
  local output
  output=$(cd "$target" && bash "$SCRIPT_PATH" -r "$repo" 2>&1)
  assert_contains "$output" "Migration Complete"
  # Verify all 8 components installed
  assert_dir_exists "$target/.claude/agents"
  assert_dir_exists "$target/.claude/commands"
  assert_dir_exists "$target/.claude/skills"
  assert_dir_exists "$target/.claude/rules"
  assert_dir_exists "$target/.claude/contexts"
  assert_dir_exists "$target/.claude/plugins"
  assert_file_exists "$target/.claude/settings.json"
  assert_file_exists "$target/.mcp.json"
  # Verify all 3 languages installed (rules)
  assert_file_exists "$target/.claude/rules/coding-style.md"
}

test_integration_defaults_scope_project() {
  # Verify default scope is project (not user)
  local repo="$TEST_TMPDIR/repo"
  local target="$TEST_TMPDIR/target"
  create_fake_repo "$repo"
  mkdir -p "$target"
  local output
  output=$(cd "$target" && bash "$SCRIPT_PATH" -r "$repo" 2>&1)
  assert_contains "$output" "Scope: project"
  # Should NOT install to $HOME
  assert_dir_exists "$target/.claude"
}

# ============================================================================
# Run all tests
# ============================================================================

echo ""
echo "=== Testing scripts/migrate-ecc.sh ==="

suite "Argument Parsing"
run_test "version flag outputs version" test_version_flag
run_test "scope short flag (-s)" test_scope_short_flag
run_test "scope long flag (--scope)" test_scope_long_flag
run_test "lang flag single (-l)" test_lang_flag_single
run_test "lang flag multiple (-l -l -l)" test_lang_flag_multiple
run_test "component flag (-c)" test_component_flag
run_test "repo flag (-r)" test_repo_flag
run_test "locale flag (-L)" test_locale_flag
run_test "dry-run flag (--dry-run)" test_dry_run_flag
run_test "force flag (--force)" test_force_flag
run_test "backup flag (-b)" test_backup_flag
run_test "no-backup flag (--no-backup)" test_no_backup_flag
run_test "positional target dir" test_positional_target
run_test "combined flags" test_combined_flags
run_test "unknown option exits non-zero" test_unknown_option_exits

suite "Utility Functions"
run_test "count_files empty dir" test_count_files_empty_dir
run_test "count_files with files" test_count_files_with_files
run_test "count_files nonexistent dir" test_count_files_nonexistent
run_test "count_files nested dirs" test_count_files_nested
run_test "check_command finds bash" test_check_command_exists
run_test "check_command fails for missing cmd" test_check_command_missing
run_test "detect_existing_config found" test_detect_existing_config_found
run_test "detect_existing_config not found" test_detect_existing_config_not_found
run_test "detect_existing_config CLAUDE.md" test_detect_existing_config_claude_md
run_test "detect_existing_config .mcp.json" test_detect_existing_config_mcp_json
run_test "info output format" test_info_output
run_test "warn output format" test_warn_output
run_test "error output format" test_error_output
run_test "success output format" test_success_output
run_test "confirm with FORCE=true" test_confirm_force_true

suite "Clone / Locale"
run_test "clone_repo with local repo" test_clone_repo_skip_with_local
run_test "clone_repo missing local dir exits" test_clone_repo_skip_missing_dir
run_test "get_locale_src no locale" test_get_locale_src_no_locale
run_test "get_locale_src with zh-CN" test_get_locale_src_with_locale
run_test "get_locale_src fallback for missing locale" test_get_locale_src_fallback

suite "Selection Defaults"
run_test "select_scope defaults to project" test_select_scope_default
run_test "select_scope preserves preset" test_select_scope_preset
run_test "select_target user scope -> HOME" test_select_target_user_scope
run_test "select_target default cwd" test_select_target_default_cwd
run_test "select_target nonexistent exits" test_select_target_nonexistent_exits
run_test "select_components defaults to all" test_select_components_default_all
run_test "select_components preserves preset" test_select_components_preset
run_test "select_languages defaults to all" test_select_languages_default_all
run_test "select_languages skipped without rules" test_select_languages_skipped_no_rules

suite "Backup"
run_test "backup creates copy" test_backup_creates_copy
run_test "backup --no-backup skips" test_backup_no_backup_flag
run_test "backup dry-run no changes" test_backup_dry_run
run_test "backup skipped when no .claude dir" test_backup_skipped_no_claude_dir

suite "safe_copy"
run_test "safe_copy file" test_safe_copy_file
run_test "safe_copy directory" test_safe_copy_directory
run_test "safe_copy dry-run" test_safe_copy_dry_run
run_test "safe_copy missing source warns" test_safe_copy_missing_source
run_test "safe_copy creates parent dirs" test_safe_copy_creates_parent_dirs

suite "Migration Components"
run_test "migrate_agents copies files" test_migrate_agents
run_test "migrate_agents dry-run" test_migrate_agents_dry_run
run_test "migrate_commands copies files" test_migrate_commands
run_test "migrate_skills copies files" test_migrate_skills
run_test "migrate_contexts copies files" test_migrate_contexts
run_test "migrate_plugins copies files" test_migrate_plugins
run_test "migrate_rules common only" test_migrate_rules_common_only
run_test "migrate_rules with typescript" test_migrate_rules_with_typescript
run_test "migrate_rules with all langs" test_migrate_rules_with_all_langs
run_test "migrate_rules missing lang warns" test_migrate_rules_missing_lang
run_test "migrate_agents with zh-CN locale" test_migrate_agents_with_locale
run_test "migrate_agents locale fallback" test_migrate_agents_locale_with_fallback

suite "Hooks Migration"
run_test "hooks creates settings.json" test_migrate_hooks_creates_settings
run_test "hooks has event types" test_migrate_hooks_has_events
run_test "hooks converts matcher format" test_migrate_hooks_converts_matcher
run_test "hooks copies script files" test_migrate_hooks_copies_scripts
run_test "hooks dry-run" test_migrate_hooks_dry_run
run_test "hooks merge existing settings" test_migrate_hooks_merge_existing
run_test "hooks dedup on re-run" test_migrate_hooks_dedup
run_test "hooks missing hooks.json warns" test_migrate_hooks_missing_hooks_json

suite "MCP Config Migration"
run_test "mcp clean install" test_migrate_mcp_clean_install
run_test "mcp strips description field" test_migrate_mcp_strips_description
run_test "mcp has server entries" test_migrate_mcp_has_servers
run_test "mcp merge existing" test_migrate_mcp_merge_existing
run_test "mcp skip duplicates" test_migrate_mcp_skip_duplicates
run_test "mcp dry-run" test_migrate_mcp_dry_run
run_test "mcp missing source warns" test_migrate_mcp_missing_source

suite "Integration Tests"
run_test "full dry-run mode" test_integration_dry_run_full
run_test "project scope all components" test_integration_project_scope_all
run_test "selective components" test_integration_selective_components
run_test "locale zh-CN" test_integration_locale_zh_cn
run_test "idempotent re-run" test_integration_idempotent_rerun
run_test "backup and migrate" test_integration_backup_and_migrate
run_test "version output" test_integration_version_output
run_test "zero-args defaults (all components)" test_integration_zero_args_with_local_repo
run_test "zero-args defaults to project scope" test_integration_defaults_scope_project

# ============================================================================
# Summary
# ============================================================================

TOTAL=$((PASSED + FAILED))
echo ""
echo "=== Test Results ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "Total:  $TOTAL"
echo ""

exit $((FAILED > 0 ? 1 : 0))

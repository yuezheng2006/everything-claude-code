#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Everything Claude Code - Migration Script
# Downloads the ECC repo and migrates Claude configurations to a target project
# ============================================================================

VERSION="1.2.0"
REPO_URL="https://github.com/affaan-m/everything-claude-code.git"
REPO_NAME="everything-claude-code"
TMP_DIR=""
CLONE_PARENT=""
TARGET_DIR=""
INSTALL_SCOPE=""  # "user" or "project"
BACKUP_DIR=""
DRY_RUN=false
FORCE=true
SKIP_CLONE=false
LOCALE=""  # "", "zh-CN", "zh-TW"
SELECTED_LANGS=()
SELECTED_COMPONENTS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================================
# Utility functions
# ============================================================================

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }

confirm() {
  local prompt="$1"
  local default="${2:-y}"
  if [[ "$FORCE" == true ]]; then return 0; fi
  local yn
  if [[ "$default" == "y" ]]; then
    read -rp "$(echo -e "${YELLOW}$prompt [Y/n]:${NC} ")" yn
    yn="${yn:-y}"
  else
    read -rp "$(echo -e "${YELLOW}$prompt [y/N]:${NC} ")" yn
    yn="${yn:-n}"
  fi
  [[ "$yn" =~ ^[Yy] ]]
}

check_command() {
  if ! command -v "$1" &>/dev/null; then
    error "'$1' is not installed. Please install it first."
    exit 1
  fi
}

cleanup() {
  if [[ -n "$CLONE_PARENT" && -d "$CLONE_PARENT" && "$SKIP_CLONE" == false ]]; then
    rm -rf "$CLONE_PARENT"
  fi
}
trap cleanup EXIT

# ============================================================================
# Usage / Help
# ============================================================================

usage() {
  cat <<EOF
${BOLD}Everything Claude Code - Migration Script v${VERSION}${NC}

${BOLD}USAGE:${NC}
  $(basename "$0") [OPTIONS] [TARGET_DIR]

${BOLD}DESCRIPTION:${NC}
  Downloads the ECC repository and migrates Claude Code configurations
  to a target project directory or user-level config (~/.claude/).

${BOLD}OPTIONS:${NC}
  -s, --scope <user|project>   Installation scope (default: interactive)
  -l, --lang <lang>            Language rules to install (repeatable)
                               Values: typescript, python, golang
  -c, --component <name>       Components to install (repeatable)
                               Values: agents, commands, skills, rules,
                                       plugins, hooks, contexts, mcp-configs
  -r, --repo <path>            Use local repo instead of cloning
  -L, --locale <locale>        Use localized docs (zh-CN, zh-TW)
                               Markdown content uses docs/<locale>/ with
                               English fallback; scripts stay original
  -d, --dry-run                Show what would be done without changes
  -f, --force                  Skip all confirmation prompts
  -b, --backup                 Force backup of existing config
      --no-backup              Skip backup even if config exists
  -h, --help                   Show this help message
  -v, --version                Show version

${BOLD}EXAMPLES:${NC}
  # Interactive mode (recommended)
  $(basename "$0")

  # Install to current project with TypeScript rules
  $(basename "$0") -s project -l typescript .

  # Install to user-level with all languages
  $(basename "$0") -s user -l typescript -l python -l golang

  # Dry run to see what would happen
  $(basename "$0") --dry-run -s project ~/my-project

  # Use already-cloned repo
  $(basename "$0") -r ./everything-claude-code -s project .

  # Use Chinese (zh-CN) localized content
  $(basename "$0") -L zh-CN -s project -l typescript .

EOF
  exit 0
}

# ============================================================================
# Argument parsing
# ============================================================================

LOCAL_REPO=""
DO_BACKUP=""  # "", "yes", "no"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--scope)
        INSTALL_SCOPE="$2"; shift 2 ;;
      -l|--lang)
        SELECTED_LANGS+=("$2"); shift 2 ;;
      -c|--component)
        SELECTED_COMPONENTS+=("$2"); shift 2 ;;
      -r|--repo)
        LOCAL_REPO="$2"; SKIP_CLONE=true; shift 2 ;;
      -L|--locale)
        LOCALE="$2"; shift 2 ;;
      -d|--dry-run)
        DRY_RUN=true; shift ;;
      -f|--force)
        FORCE=true; shift ;;
      -b|--backup)
        DO_BACKUP="yes"; shift ;;
      --no-backup)
        DO_BACKUP="no"; shift ;;
      -h|--help)
        usage ;;
      -v|--version)
        echo "migrate-ecc v${VERSION}"; exit 0 ;;
      -*)
        error "Unknown option: $1"; usage ;;
      *)
        TARGET_DIR="$1"; shift ;;
    esac
  done
}

# ============================================================================
# Clone / locate repo
# ============================================================================

clone_repo() {
  if [[ "$SKIP_CLONE" == true ]]; then
    if [[ ! -d "$LOCAL_REPO" ]]; then
      error "Local repo not found: $LOCAL_REPO"
      exit 1
    fi
    TMP_DIR="$(cd "$LOCAL_REPO" && pwd)"
    info "Using local repo: $TMP_DIR"
    return
  fi

  check_command git
  CLONE_PARENT="$(mktemp -d)"
  info "Cloning $REPO_URL into temp directory..."
  if ! git clone --depth 1 "$REPO_URL" "$CLONE_PARENT/$REPO_NAME" 2>&1; then
    error "Failed to clone repository"
    exit 1
  fi
  TMP_DIR="$CLONE_PARENT/$REPO_NAME"
  success "Repository cloned successfully"
}

# ============================================================================
# Locale-aware source resolution
# For markdown content (agents, commands, skills, rules, contexts, plugins):
#   - If --locale is set, prefer docs/<locale>/<component>/
#   - Fall back to root-level <component>/ for missing files
# For code (scripts, hooks, mcp-configs): always use root-level
# ============================================================================

# Get the localized source dir for a component, with English fallback
get_locale_src() {
  local component="$1"
  local locale_dir="$TMP_DIR/docs/$LOCALE/$component"
  local root_dir="$TMP_DIR/$component"

  if [[ -n "$LOCALE" && -d "$locale_dir" ]]; then
    echo "$locale_dir"
  else
    echo "$root_dir"
  fi
}

# Merge: copy localized content first, then fill gaps from English original
copy_with_fallback() {
  local component="$1"
  local dest="$2"
  local label="$3"
  local locale_dir="$TMP_DIR/docs/$LOCALE/$component"
  local root_dir="$TMP_DIR/$component"

  if [[ -z "$LOCALE" ]]; then
    # No locale - just copy root
    safe_copy "$root_dir" "$dest" "$label"
    return
  fi

  # Step 1: Copy localized content (primary)
  if [[ -d "$locale_dir" ]]; then
    local lcount; lcount=$(count_files "$locale_dir")
    info "Copying $LOCALE localized content ($lcount files)..."
    safe_copy "$locale_dir" "$dest" "$label ($LOCALE)"
  fi

  # Step 2: Fill missing files from English original (fallback)
  if [[ -d "$root_dir" && "$DRY_RUN" == false ]]; then
    local fallback_count=0
    while IFS= read -r -d '' file; do
      local rel="${file#"$root_dir"/}"
      if [[ ! -f "$dest/$rel" ]]; then
        local target_dir; target_dir="$(dirname "$dest/$rel")"
        mkdir -p "$target_dir"
        cp "$file" "$dest/$rel"
        fallback_count=$((fallback_count + 1))
      fi
    done < <(find "$root_dir" -type f -print0 2>/dev/null)
    if [[ "$fallback_count" -gt 0 ]]; then
      info "Filled $fallback_count missing files from English fallback"
    fi
  elif [[ -d "$root_dir" && "$DRY_RUN" == true ]]; then
    # In dry-run, estimate fallback count
    local locale_count=0 root_count=0
    [[ -d "$locale_dir" ]] && locale_count=$(count_files "$locale_dir")
    root_count=$(count_files "$root_dir")
    if [[ "$root_count" -gt "$locale_count" ]]; then
      info "[DRY RUN] Would fill ~$((root_count - locale_count)) files from English fallback"
    fi
  fi
}

# ============================================================================
# Detect existing Claude configuration
# ============================================================================

detect_existing_config() {
  local dir="$1"
  local found=()

  [[ -d "$dir/.claude" ]]          && found+=(".claude/")
  [[ -f "$dir/CLAUDE.md" ]]        && found+=("CLAUDE.md")
  [[ -d "$dir/.claude/agents" ]]   && found+=(".claude/agents/")
  [[ -d "$dir/.claude/commands" ]]  && found+=(".claude/commands/")
  [[ -d "$dir/.claude/skills" ]]   && found+=(".claude/skills/")
  [[ -d "$dir/.claude/rules" ]]    && found+=(".claude/rules/")
  [[ -f "$dir/.claude/settings.json" ]] && found+=(".claude/settings.json")
  [[ -f "$dir/.mcp.json" ]]         && found+=(".mcp.json")

  if [[ ${#found[@]} -gt 0 ]]; then
    warn "Existing Claude configuration detected in $dir:"
    for item in "${found[@]}"; do
      echo -e "  ${YELLOW}-${NC} $item"
    done
    return 0
  fi
  return 1
}

count_files() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    find "$dir" -type f | wc -l | tr -d ' '
  else
    echo "0"
  fi
}

# ============================================================================
# Interactive selection
# ============================================================================

select_scope() {
  if [[ -n "$INSTALL_SCOPE" ]]; then return; fi
  # Default: project-level (no optional args = non-interactive)
  INSTALL_SCOPE="project"
  info "Scope: $INSTALL_SCOPE (default)"
}

select_target() {
  if [[ "$INSTALL_SCOPE" == "user" ]]; then
    TARGET_DIR="$HOME"
    return
  fi

  if [[ -n "$TARGET_DIR" ]]; then
    TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd)" || {
      error "Target directory does not exist: $TARGET_DIR"
      exit 1
    }
    return
  fi
  # Default: current directory (no optional args = non-interactive)
  TARGET_DIR="$(pwd)"
  info "Target: $TARGET_DIR (default)"
}

select_components() {
  if [[ ${#SELECTED_COMPONENTS[@]} -gt 0 ]]; then return; fi
  # Default: all components (no optional args = non-interactive)
  local all_components=("agents" "commands" "skills" "rules" "plugins" "hooks" "contexts" "mcp-configs")
  SELECTED_COMPONENTS=("${all_components[@]}")
  success "Selected: ${SELECTED_COMPONENTS[*]} (default: all)"
}

select_languages() {
  if [[ ${#SELECTED_LANGS[@]} -gt 0 ]]; then return; fi
  local has_rules=false
  for comp in "${SELECTED_COMPONENTS[@]}"; do
    [[ "$comp" == "rules" ]] && has_rules=true
  done
  if [[ "$has_rules" == false ]]; then return; fi
  # Default: all languages (no optional args = non-interactive)
  SELECTED_LANGS=("typescript" "python" "golang")
  info "Languages: ${SELECTED_LANGS[*]} (default: all)"
}

# ============================================================================
# Backup
# ============================================================================

backup_config() {
  local claude_dir="$TARGET_DIR/.claude"
  if [[ ! -d "$claude_dir" ]]; then return; fi

  if [[ "$DO_BACKUP" == "no" ]]; then
    warn "Skipping backup (--no-backup)"
    return
  fi

  if [[ "$DO_BACKUP" != "yes" ]]; then
    if ! confirm "Back up existing .claude/ before migration?"; then
      return
    fi
  fi

  BACKUP_DIR="$TARGET_DIR/.claude-backup-$(date +%Y%m%d-%H%M%S)"
  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would backup $claude_dir -> $BACKUP_DIR"
    return
  fi

  cp -r "$claude_dir" "$BACKUP_DIR"
  success "Backup created: $BACKUP_DIR"
}

# ============================================================================
# Copy helper (respects dry-run, handles merge)
# ============================================================================

safe_copy() {
  local src="$1"
  local dest="$2"
  local label="${3:-}"

  if [[ ! -e "$src" ]]; then
    warn "Source not found: $src"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    if [[ -d "$src" ]]; then
      local count
      count=$(count_files "$src")
      info "[DRY RUN] Would copy $count files from $label"
    else
      info "[DRY RUN] Would copy $(basename "$src")"
    fi
    return
  fi

  local dest_dir
  dest_dir="$(dirname "$dest")"
  mkdir -p "$dest_dir"

  if [[ -d "$src" ]]; then
    mkdir -p "$dest"
    cp -r "$src"/. "$dest"/ 2>/dev/null || cp -r "$src"/* "$dest"/ 2>/dev/null || true
  else
    cp "$src" "$dest"
  fi
}
# ============================================================================
# Migration functions for each component
# ============================================================================

migrate_agents() {
  local src; src="$(get_locale_src agents)"
  local dest="$TARGET_DIR/.claude/agents"
  if [[ ! -d "$src" && ! -d "$TMP_DIR/agents" ]]; then warn "No agents found in source"; return; fi
  local count; count=$(count_files "$TMP_DIR/agents")
  info "Installing agents ($count total)..."
  if [[ "$DRY_RUN" == false ]]; then mkdir -p "$dest"; fi
  copy_with_fallback "agents" "$dest" "agents/"
  if [[ "$DRY_RUN" == false ]]; then success "Agents installed"; fi
}

migrate_commands() {
  local src; src="$(get_locale_src commands)"
  local dest="$TARGET_DIR/.claude/commands"
  if [[ ! -d "$src" && ! -d "$TMP_DIR/commands" ]]; then warn "No commands found in source"; return; fi
  local count; count=$(count_files "$TMP_DIR/commands")
  info "Installing commands ($count total)..."
  if [[ "$DRY_RUN" == false ]]; then mkdir -p "$dest"; fi
  copy_with_fallback "commands" "$dest" "commands/"
  if [[ "$DRY_RUN" == false ]]; then success "Commands installed"; fi
}

migrate_skills() {
  local src; src="$(get_locale_src skills)"
  local dest="$TARGET_DIR/.claude/skills"
  if [[ ! -d "$src" && ! -d "$TMP_DIR/skills" ]]; then warn "No skills found in source"; return; fi
  local count; count=$(count_files "$TMP_DIR/skills")
  info "Installing skills ($count total)..."
  if [[ "$DRY_RUN" == false ]]; then mkdir -p "$dest"; fi
  copy_with_fallback "skills" "$dest" "skills/"
  if [[ "$DRY_RUN" == false ]]; then success "Skills installed"; fi
}

migrate_rules() {
  local dest="$TARGET_DIR/.claude/rules"
  if [[ ! -d "$TMP_DIR/rules" ]]; then warn "No rules found in source"; return; fi
  if [[ "$DRY_RUN" == false ]]; then mkdir -p "$dest"; fi

  # Rules use locale-aware copy with fallback
  # The locale version has flat structure; root has common/typescript/python/golang
  # We copy locale first (flat), then fill from root common + selected langs
  if [[ -n "$LOCALE" ]]; then
    local locale_rules="$TMP_DIR/docs/$LOCALE/rules"
    if [[ -d "$locale_rules" ]]; then
      local lcount; lcount=$(count_files "$locale_rules")
      info "Installing $LOCALE localized rules ($lcount files)..."
      safe_copy "$locale_rules" "$dest" "rules/ ($LOCALE)"
    fi
  fi

  # Always install common rules (fill gaps or primary if no locale)
  if [[ -d "$TMP_DIR/rules/common" ]]; then
    local count; count=$(count_files "$TMP_DIR/rules/common")
    if [[ -n "$LOCALE" ]]; then
      # Fill missing from common
      if [[ "$DRY_RUN" == false ]]; then
        local fb=0
        while IFS= read -r -d '' file; do
          local rel="${file#"$TMP_DIR/rules/common"/}"
          if [[ ! -f "$dest/$rel" ]]; then
            cp "$file" "$dest/$rel"
            fb=$((fb + 1))
          fi
        done < <(find "$TMP_DIR/rules/common" -type f -print0 2>/dev/null)
        if [[ "$fb" -gt 0 ]]; then info "Filled $fb common rules from English fallback"; fi
      fi
    else
      info "Installing common rules ($count files)..."
      safe_copy "$TMP_DIR/rules/common" "$dest" "rules/common/"
    fi
  fi

  # Install language-specific rules (always from root - no locale version)
  # Each language gets its own subdirectory to avoid overwriting common rules
  for lang in "${SELECTED_LANGS[@]}"; do
    if [[ -d "$TMP_DIR/rules/$lang" ]]; then
      local count; count=$(count_files "$TMP_DIR/rules/$lang")
      info "Installing $lang rules ($count files)..."
      if [[ "$DRY_RUN" == false ]]; then mkdir -p "$dest/$lang"; fi
      safe_copy "$TMP_DIR/rules/$lang" "$dest/$lang" "rules/$lang/"
    else
      warn "Language rules not found: $lang"
    fi
  done

  if [[ "$DRY_RUN" == false ]]; then success "Rules installed (common${SELECTED_LANGS[*]:+ + ${SELECTED_LANGS[*]}})"; fi
}

migrate_contexts() {
  local src; src="$(get_locale_src contexts)"
  local dest="$TARGET_DIR/.claude/contexts"
  if [[ ! -d "$src" && ! -d "$TMP_DIR/contexts" ]]; then warn "No contexts found in source"; return; fi
  local count; count=$(count_files "$TMP_DIR/contexts")
  info "Installing contexts ($count total)..."
  if [[ "$DRY_RUN" == false ]]; then mkdir -p "$dest"; fi
  copy_with_fallback "contexts" "$dest" "contexts/"
  if [[ "$DRY_RUN" == false ]]; then success "Contexts installed"; fi
}

migrate_plugins() {
  local dest="$TARGET_DIR/.claude/plugins"

  if [[ "$DRY_RUN" == false ]]; then mkdir -p "$dest"; fi

  local total=0

  # Copy plugins/ directory (locale-aware)
  local plugins_src; plugins_src="$(get_locale_src plugins)"
  if [[ -d "$plugins_src" ]]; then
    local count; count=$(count_files "$plugins_src")
    info "Installing plugins ($count files)..."
    safe_copy "$plugins_src" "$dest" "plugins/"
    total=$((total + count))
  fi
  # Fill from English fallback if locale
  if [[ -n "$LOCALE" && -d "$TMP_DIR/plugins" && "$DRY_RUN" == false ]]; then
    while IFS= read -r -d '' file; do
      local rel="${file#"$TMP_DIR/plugins"/}"
      if [[ ! -f "$dest/$rel" ]]; then
        mkdir -p "$(dirname "$dest/$rel")"
        cp "$file" "$dest/$rel"
      fi
    done < <(find "$TMP_DIR/plugins" -type f -print0 2>/dev/null)
  fi

  # Do NOT copy .claude-plugin/ to target - that is for the ECC repo only, not project config

  if [[ "$DRY_RUN" == false ]]; then success "Plugins installed ($total files total)"; fi
}

migrate_hooks() {
  local src="$TMP_DIR/hooks/hooks.json"
  local dest="$TARGET_DIR/.claude/settings.json"
  if [[ ! -f "$src" ]]; then warn "No hooks.json found in source"; return; fi

  info "Processing hooks -> .claude/settings.json ..."

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would convert and merge hooks into .claude/settings.json"
    return
  fi

  if ! command -v node &>/dev/null; then
    warn "Node.js required for hooks conversion but not found"
    warn "Skipping hooks installation"
    return
  fi

  # Copy the hook scripts and their dependencies (lib/) so require('../lib/...') resolves
  local hooks_scripts_src="$TMP_DIR/scripts/hooks"
  local hooks_scripts_dest="$TARGET_DIR/.claude/scripts/hooks"
  local hooks_lib_src="$TMP_DIR/scripts/lib"
  local hooks_lib_dest="$TARGET_DIR/.claude/scripts/lib"
  if [[ -d "$hooks_scripts_src" ]]; then
    mkdir -p "$hooks_scripts_dest"
    cp -r "$hooks_scripts_src"/. "$hooks_scripts_dest"/
    info "Hook scripts copied to .claude/scripts/hooks/"
  fi
  if [[ -d "$hooks_lib_src" ]]; then
    mkdir -p "$hooks_lib_dest"
    cp -r "$hooks_lib_src"/. "$hooks_lib_dest"/
    info "Hook dependencies (lib) copied to .claude/scripts/lib/"
  fi

  # Write the conversion script to a temp file to avoid bash escaping issues
  local converter; converter="$(mktemp)"
  trap "rm -f '$converter'" RETURN

  cat > "$converter" << 'CONVERTER_EOF'
const fs = require('fs');
const path = require('path');
const [destPath, srcPath, scriptsDir] = process.argv.slice(2);

const srcData = JSON.parse(fs.readFileSync(srcPath, 'utf8'));

// Parse deprecated expression-based matcher into {toolMatcher, field, pattern, negate}
function parseMatcher(m) {
  if (!m || m === '*') return { toolMatcher: m || '*' };
  if (!m.includes('tool ==') && !m.includes('tool_input')) return { toolMatcher: m };

  // OR: tool == "Edit" || tool == "Write"
  const orParts = m.match(/tool\s*==\s*"(\w+)"\s*\|\|\s*tool\s*==\s*"(\w+)"/);
  if (orParts) return { toolMatcher: orParts[1] + '|' + orParts[2] };

  // Extract tool name
  const toolMatch = m.match(/tool\s*==\s*"(\w+)"/);
  const toolName = toolMatch ? toolMatch[1] : '*';

  // Extract tool_input condition: tool_input.field matches "pattern"
  const inputMatch = m.match(/tool_input\.(\w+)\s*matches\s*"((?:[^"\\]|\\.)*)"/);
  if (inputMatch) {
    return { toolMatcher: toolName, field: inputMatch[1], pattern: inputMatch[2] };
  }

  return { toolMatcher: toolName };
}

// Wrap a command that doesn't read stdin with stdin-based filtering.
// Generates a small script file and returns a command that runs it.
// The script reads stdin, checks the tool_input condition, and runs the original logic if matched.
function wrapCommand(originalCmd, field, pattern, scriptsDir, index) {
  const p = pattern.replace(/\\\\/g, '\\');

  // Try to extract JS code from node -e "..." format
  const nodeMatch = originalCmd.match(/^node\\s+-e\\s+"([\\s\\S]*)"$/);
  let jsLogic;
  if (nodeMatch) {
    // Unescape the JS code (was inside double quotes in shell)
    jsLogic = nodeMatch[1].replace(/\\\\"/g, '"').replace(/\\\\\\\\/g, '\\\\');
  } else {
    // Can't extract - use execSync to run the original command
    jsLogic = `const{execSync}=require("child_process");try{execSync(${JSON.stringify(originalCmd)},{stdio:["pipe","inherit","inherit"],input:d})}catch(e){process.exit(e.status||1)}`;
  }

  // Write a wrapper script file
  const scriptName = 'hook-filter-' + index + '.js';
  const scriptPath = scriptsDir + '/' + scriptName;
  const scriptContent = [
    '// Auto-generated hook filter by migrate-ecc.sh',
    '// Filters: tool_input.' + field + ' matches /' + p + '/',
    'let d = "";',
    'process.stdin.on("data", c => d += c);',
    'process.stdin.on("end", () => {',
    '  const input = JSON.parse(d);',
    '  const val = (input.tool_input && input.tool_input.' + field + ') || "";',
    '  if (new RegExp(' + JSON.stringify(p) + ').test(val)) {',
    '    ' + jsLogic,
    '  }',
    '  // Pass through (unless process.exit was called above)',
    '  console.log(d);',
    '});',
  ].join('\n');

  const fs = require('fs');
  const path = require('path');
  fs.mkdirSync(scriptsDir, { recursive: true });
  fs.writeFileSync(scriptPath, scriptContent);

  return 'node "$CLAUDE_PROJECT_DIR/.claude/scripts/hooks/' + scriptName + '"';
}

// Convert all hooks to official format
let wrapIndex = 0;
function convertHooks(data) {
  const result = {};
  for (const [event, entries] of Object.entries(data.hooks || {})) {
    result[event] = [];
    for (const entry of entries) {
      const parsed = parseMatcher(entry.matcher);
      const converted = { matcher: parsed.toolMatcher, hooks: [] };

      for (const hook of entry.hooks) {
        const newHook = { type: hook.type };

        let cmd = hook.command || '';
        // Replace ${CLAUDE_PLUGIN_ROOT} with $CLAUDE_PROJECT_DIR/.claude
        cmd = cmd.replace(/\$\{CLAUDE_PLUGIN_ROOT\}/g, '$CLAUDE_PROJECT_DIR/.claude');

        // If there's a tool_input condition and command doesn't read stdin, wrap it
        if (parsed.field && parsed.pattern && !cmd.includes('process.stdin')) {
          cmd = wrapCommand(cmd, parsed.field, parsed.pattern, scriptsDir, wrapIndex++);
        }

        newHook.command = cmd;
        if (hook.async) newHook.async = hook.async;
        if (hook.timeout) newHook.timeout = hook.timeout;
        converted.hooks.push(newHook);
      }

      result[event].push(converted);
    }
  }
  return result;
}

const convertedHooks = convertHooks(srcData);

// Merge into existing settings.json or create new one
let settings = {};
if (fs.existsSync(destPath)) {
  settings = JSON.parse(fs.readFileSync(destPath, 'utf8'));
}
if (!settings.hooks) settings.hooks = {};

let added = 0, skipped = 0;
for (const [event, entries] of Object.entries(convertedHooks)) {
  if (!settings.hooks[event]) settings.hooks[event] = [];
  for (const entry of entries) {
    // Dedup by matcher + first hook command
    const key = entry.matcher + '::' + (entry.hooks[0]?.command || '').slice(0, 80);
    const isDup = settings.hooks[event].some(e => {
      const eKey = e.matcher + '::' + (e.hooks[0]?.command || '').slice(0, 80);
      return eKey === key;
    });
    if (isDup) { skipped++; continue; }
    settings.hooks[event].push(entry);
    added++;
  }
}

fs.writeFileSync(destPath, JSON.stringify(settings, null, 2) + '\n');
console.error('[Hooks] Converted to official format: ' + added + ' added, ' + skipped + ' skipped');
CONVERTER_EOF

  mkdir -p "$(dirname "$dest")"
  local hooks_scripts_dir="$TARGET_DIR/.claude/scripts/hooks"
  mkdir -p "$hooks_scripts_dir"
  node "$converter" "$dest" "$src" "$hooks_scripts_dir"
  rm -f "$converter"
  success "Hooks converted and installed into .claude/settings.json"
  info "Matchers converted from expression syntax to official regex format"
}

migrate_mcp_configs() {
  local src="$TMP_DIR/mcp-configs/mcp-servers.json"
  local dest="$TARGET_DIR/.mcp.json"
  if [[ ! -f "$src" ]]; then warn "No MCP configs found in source"; return; fi

  info "Processing MCP server configurations -> .mcp.json ..."

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would install MCP configs to .mcp.json (project-scoped)"
    return
  fi

  if ! command -v node &>/dev/null; then
    warn "Node.js not found - copying raw mcp-servers.json as .mcp.json"
    cp "$src" "$dest"
    success "MCP config installed as .mcp.json (may contain non-standard fields)"
    return
  fi

  warn "MCP configs contain placeholder API keys (YOUR_*_HERE)"
  warn "Review and add your actual keys before enabling"

  if [[ -f "$dest" ]]; then
    # Merge: add new servers, skip duplicates
    node -e "
      const fs = require('fs');
      const [destPath, srcPath] = process.argv.slice(1);
      const existing = JSON.parse(fs.readFileSync(destPath, 'utf8'));
      const incoming = JSON.parse(fs.readFileSync(srcPath, 'utf8'));
      if (!existing.mcpServers) existing.mcpServers = {};
      const incomingServers = incoming.mcpServers || {};
      let added = 0, skipped = 0;
      for (const [name, config] of Object.entries(incomingServers)) {
        if (existing.mcpServers[name]) { skipped++; continue; }
        const clean = { ...config };
        delete clean.description;
        existing.mcpServers[name] = clean;
        added++;
      }
      fs.writeFileSync(destPath, JSON.stringify(existing, null, 2) + '\n');
      console.error('[MCP] Merged: ' + added + ' added, ' + skipped + ' skipped (already exist)');
    " "$dest" "$src"
    success "MCP configs merged into existing .mcp.json"
  else
    # Clean install: strip description and _comments, write .mcp.json
    node -e "
      const fs = require('fs');
      const [destPath, srcPath] = process.argv.slice(1);
      const data = JSON.parse(fs.readFileSync(srcPath, 'utf8'));
      const result = { mcpServers: {} };
      for (const [name, config] of Object.entries(data.mcpServers || {})) {
        const clean = { ...config };
        delete clean.description;
        result.mcpServers[name] = clean;
      }
      fs.writeFileSync(destPath, JSON.stringify(result, null, 2) + '\n');
    " "$dest" "$src"
    success "MCP config installed as .mcp.json (project-scoped)"
  fi
  warn "Edit .mcp.json to add your API keys and remove unused servers"
  info "Tip: Use 'claude mcp add --scope project <name> <url>' to add more servers"
}
# ============================================================================
# Summary and next steps
# ============================================================================

print_summary() {
  header "Migration Complete"

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}This was a dry run. No changes were made.${NC}"
    echo ""
    return
  fi

  echo -e "${GREEN}Configuration migrated successfully.${NC}"
  echo ""
  echo -e "${BOLD}Target:${NC} $TARGET_DIR"
  echo -e "${BOLD}Scope:${NC}  $INSTALL_SCOPE"
  if [[ -n "$LOCALE" ]]; then
    echo -e "${BOLD}Locale:${NC} $LOCALE (with English fallback)"
  fi
  echo -e "${BOLD}Components:${NC} ${SELECTED_COMPONENTS[*]}"
  if [[ ${#SELECTED_LANGS[@]} -gt 0 ]]; then
    echo -e "${BOLD}Languages:${NC}  common + ${SELECTED_LANGS[*]}"
  fi
  if [[ -n "$BACKUP_DIR" ]]; then
    echo -e "${BOLD}Backup:${NC} $BACKUP_DIR"
  fi

  echo ""
  echo -e "${BOLD}${CYAN}Next Steps:${NC}"
  echo ""

  local step=1

  # Check if hooks were installed
  for comp in "${SELECTED_COMPONENTS[@]}"; do
    if [[ "$comp" == "hooks" ]]; then
      echo -e "  ${step}. Review hooks in ${BOLD}.claude/settings.json${NC}"
      echo "     Hooks use official matcher format (simple regex on tool name)"
      echo "     Some hooks reference \$CLAUDE_PROJECT_DIR - verify paths are correct"
      step=$((step + 1))
      break
    fi
  done

  # Check if MCP was installed
  for comp in "${SELECTED_COMPONENTS[@]}"; do
    if [[ "$comp" == "mcp-configs" ]]; then
      echo -e "  ${step}. Edit ${BOLD}.mcp.json${NC} - replace YOUR_*_HERE with actual API keys"
      echo "     Disable unused MCP servers to preserve context window"
      echo "     Use 'claude mcp add --scope project <name> <url>' to add more"
      step=$((step + 1))
      break
    fi
  done

  echo -e "  ${step}. Verify installation:"
  echo "     claude --version   # Requires v2.1.0+"
  step=$((step + 1))

  echo -e "  ${step}. Try a command:"
  echo "     /plan \"Add user authentication\""
  step=$((step + 1))

  echo ""
  echo -e "${BOLD}Tips:${NC}"
  echo "  - Keep under 10 MCP servers enabled per project"
  echo "  - Use /plugin list to see available commands"
  echo "  - Run with --dry-run first to preview changes"
  echo "  - Customize configs for your workflow - remove what you don't use"
  echo ""
}

# ============================================================================
# Diff / preview existing vs new
# ============================================================================

show_diff_preview() {
  local claude_dir="$TARGET_DIR/.claude"
  if [[ ! -d "$claude_dir" ]]; then return; fi

  header "Configuration Diff Preview"
  info "Comparing existing config with ECC source..."
  echo ""

  local dirs=("agents" "commands" "skills" "rules" "plugins" "contexts")
  for dir in "${dirs[@]}"; do
    local existing="$claude_dir/$dir"
    local source="$TMP_DIR/$dir"
    if [[ -d "$existing" && -d "$source" ]]; then
      local existing_count; existing_count=$(count_files "$existing")
      local source_count; source_count=$(count_files "$source")
      local new_files=0
      while IFS= read -r -d '' file; do
        local rel="${file#"$source"/}"
        if [[ ! -f "$existing/$rel" ]]; then
          new_files=$((new_files + 1))
        fi
      done < <(find "$source" -type f -print0 2>/dev/null)
      echo -e "  ${BOLD}$dir/${NC}: $existing_count existing, $source_count in ECC, $new_files new"
    fi
  done
  echo ""
}
# ============================================================================
# Main
# ============================================================================

main() {
  echo -e "${BOLD}${CYAN}"
  echo "  Everything Claude Code - Migration Script v${VERSION}"
  echo -e "${NC}"

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}  [DRY RUN MODE - no changes will be made]${NC}"
    echo ""
  fi

  # Step 1: Clone or locate repo
  header "Step 1: Source Repository"
  clone_repo

  # Step 2: Select scope and target
  header "Step 2: Installation Target"
  select_scope
  select_target
  info "Scope: $INSTALL_SCOPE"
  info "Target: $TARGET_DIR"

  # Step 3: Detect existing config
  header "Step 3: Existing Configuration Check"
  if detect_existing_config "$TARGET_DIR"; then
    echo ""
    show_diff_preview
    if [[ "$FORCE" != true ]]; then
      if ! confirm "Continue with migration? (existing files will be merged/overwritten)"; then
        info "Migration cancelled"
        exit 0
      fi
    fi
    backup_config
  else
    success "No existing Claude configuration found - clean install"
  fi

  # Step 4: Select components
  header "Step 4: Component Selection"
  select_components
  select_languages

  # Step 5: Confirm and execute
  header "Step 5: Migration"
  echo -e "  ${BOLD}Target:${NC}     $TARGET_DIR"
  echo -e "  ${BOLD}Scope:${NC}      $INSTALL_SCOPE"
  echo -e "  ${BOLD}Components:${NC} ${SELECTED_COMPONENTS[*]}"
  if [[ ${#SELECTED_LANGS[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Languages:${NC}  ${SELECTED_LANGS[*]}"
  fi
  echo ""

  if [[ "$FORCE" != true && "$DRY_RUN" != true ]]; then
    if ! confirm "Proceed with migration?"; then
      info "Migration cancelled"
      exit 0
    fi
  fi

  # Execute migration for each selected component
  for comp in "${SELECTED_COMPONENTS[@]}"; do
    case "$comp" in
      agents)      migrate_agents ;;
      commands)    migrate_commands ;;
      skills)      migrate_skills ;;
      rules)       migrate_rules ;;
      plugins)     migrate_plugins ;;
      hooks)       migrate_hooks ;;
      contexts)    migrate_contexts ;;
      mcp-configs) migrate_mcp_configs ;;
      *) warn "Unknown component: $comp" ;;
    esac
  done

  # Step 6: Summary
  print_summary
}

# ============================================================================
# Entry point
# ============================================================================

parse_args "$@"
main

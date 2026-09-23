#!/usr/bin/env bash
#
# validate_plugin.sh — Validate this single-plugin, multi-harness repository.
#
# The repository root IS the plugin. It must load under Claude Code, Cursor, and
# Codex from one source tree, which means:
#   - three manifests with matching name/version:
#       .claude-plugin/plugin.json   (Claude Code)
#       .cursor-plugin/plugin.json   (Cursor)
#       .codex-plugin/plugin.json    (Codex)
#   - shared components at the repo root (skills/, commands/, agents/, rules/);
#   - a generated one-entry catalog, .claude-plugin/marketplace.json, that points
#     back at the repo root so Claude Code and Codex can install the plugin.
#
# The per-manifest rules mirror the official Cursor validator
# (fieldsphere/cursor-team-marketplace-template, scripts/validate-template.mjs).
#
# Requirements: bash (3.2+), jq.
#
# Usage:
#   scripts/validate_plugin.sh [--strict]
#
#   --strict   Treat warnings as errors (use this in CI).
#
# Exit code: 0 when validation passes, 1 when any error (or, with --strict,
# any warning) is found.

set -uo pipefail

# --- Locate repo root (parent of this script's scripts/ directory) -----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Options -----------------------------------------------------------------
STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict)  STRICT=1 ;;
    -h|--help) grep '^#' "${BASH_SOURCE[0]}" | sed '1d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Manifests every plugin must ship.
REQUIRED_PLATFORMS=(claude cursor codex)

# --- Output helpers ----------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_OFF=""
fi

ERRORS=0
WARNINGS=0

err()  { ERRORS=$((ERRORS + 1));   printf '%s✗ ERROR%s   %s\n' "$C_RED" "$C_OFF" "$1" >&2; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '%s! WARN%s    %s\n' "$C_YEL" "$C_OFF" "$1" >&2; }
info() { printf '%s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }

# Pattern mirrors the upstream Cursor validator.
PLUGIN_NAME_RE='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'

# rel <abs-path> -> path relative to repo root, for tidy messages.
rel() { printf '%s' "${1#"$ROOT"/}"; }

# --- jq / dependency guard ---------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "${C_RED}jq is required but not installed.${C_OFF}" >&2
  echo "Install it with: apt-get install jq  |  brew install jq" >&2
  exit 2
fi

# --- Generic helpers ---------------------------------------------------------

# is_safe_rel <path> : true for http(s) URLs or relative paths that don't
# escape their base (no leading / and no ../ traversal).
is_safe_rel() {
  local v="$1"
  [ -n "$v" ] || return 1
  case "$v" in
    http://*|https://*) return 0 ;;
    /*) return 1 ;;
    ../*|..) return 1 ;;
    *) [[ "$v" == *"/../"* ]] && return 1; return 0 ;;
  esac
}

# json_valid <file> : parse check with jq.
json_valid() { jq empty "$1" >/dev/null 2>&1; }

# fm_block <file> : print the YAML frontmatter block (between the leading
# `---` line and the next `---` line). Exit non-zero if there is no valid
# frontmatter block. Mirrors parseFrontmatter() in the upstream validator.
fm_block() {
  awk '
    NR==1 { if ($0 != "---") exit 1; next }
    /^---[[:space:]]*$/ { found=1; exit 0 }
    { print }
    END { if (!found) exit 1 }
  ' "$1"
}

# validate_frontmatter_file <file> <component> <key...>
validate_frontmatter_file() {
  local file="$1" component="$2"; shift 2
  local block key val
  if ! block="$(fm_block "$file")"; then
    err "$component file missing YAML frontmatter: $(rel "$file")"
    return
  fi
  for key in "$@"; do
    val="$(printf '%s\n' "$block" | sed -n "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//p" | head -1)"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    if [ -z "$val" ]; then
      err "$component file missing \"$key\" in frontmatter: $(rel "$file")"
    fi
  done
}

# --- Manifests ---------------------------------------------------------------

# validate_referenced_paths <manifest> <platform>
validate_referenced_paths() {
  local manifest="$1" platform="$2"
  local field val
  # Dotted names reach into nested objects (Codex keeps its images under "interface").
  for field in logo rules skills agents commands hooks mcpServers outputStyles apps \
               interface.logo interface.composerIcon interface.screenshots; do
    while IFS= read -r val; do
      [ -n "$val" ] || continue
      case "$val" in http://*|https://*) continue ;; esac
      if ! is_safe_rel "$val"; then
        err "[$platform] field \"$field\" has invalid path \"$val\"."
        continue
      fi
      # Codex ignores (with only a warning) manifest paths that don't start with "./".
      if [ "$platform" = codex ] && [[ "$val" != ./?* ]]; then
        err "[$platform] field \"$field\" must start with \"./\" (got: \"$val\")."
        continue
      fi
      [ -e "$ROOT/$val" ] || err "[$platform] field \"$field\" references missing path \"$val\"."
    done < <(jq -r --arg f "$field" '
      def paths_of:
        if type=="string" then .
        elif type=="array" then (.[] | paths_of)
        elif type=="object" then ((.path // empty), (.file // empty))
        else empty end;
      (getpath($f | split(".")) // empty) | paths_of' "$manifest")
  done
}

# validate_manifest <platform> <required: 0|1> : returns 0 if a usable manifest exists.
validate_manifest() {
  local platform="$1" required="$2"
  local dir=".${platform}-plugin"
  local manifest="$ROOT/$dir/plugin.json"

  if [ ! -f "$manifest" ]; then
    [ "$required" = 1 ] && err "missing $platform manifest ($dir/plugin.json) — the plugin must support every harness."
    return 1
  fi
  info "Validating $platform manifest ($dir/plugin.json)"
  if ! json_valid "$manifest"; then
    err "[$platform] manifest contains invalid JSON: $dir/plugin.json"
    return 1
  fi

  local name
  name="$(jq -r '.name // empty' "$manifest")"
  [[ "$name" =~ $PLUGIN_NAME_RE ]] || \
    err "[$platform] \"name\" must be lowercase alphanumerics/hyphens/periods (got: \"${name:-<missing>}\")."

  validate_referenced_paths "$manifest" "$platform"

  # Components live at the repo root; anything inside the manifest dir is silently ignored.
  local comp
  for comp in skills commands agents rules hooks; do
    [ -e "$ROOT/$dir/$comp" ] && err "[$platform] $dir/$comp is inside the manifest directory — move it to the repo root."
  done
  return 0
}

# validate_manifest_parity : every manifest must agree on name and version.
validate_manifest_parity() {
  local base="$ROOT/.claude-plugin/plugin.json"
  json_valid "$base" 2>/dev/null || return
  local platform other field a b
  for platform in cursor codex; do
    other="$ROOT/.${platform}-plugin/plugin.json"
    [ -f "$other" ] && json_valid "$other" || continue
    for field in name version; do
      a="$(jq -r --arg f "$field" '.[$f] // empty' "$base")"
      b="$(jq -r --arg f "$field" '.[$f] // empty' "$other")"
      [ "$a" = "$b" ] || err "\"$field\" differs between manifests: claude=\"$a\" $platform=\"$b\"."
    done
    a="$(jq -r '.description // empty' "$base")"
    b="$(jq -r '.description // empty' "$other")"
    [ "$a" = "$b" ] || warn "\"description\" differs between the claude and $platform manifests."
  done
}

# --- Catalog (.claude-plugin/marketplace.json, generated) --------------------
validate_catalog() {
  local mk="$ROOT/.claude-plugin/marketplace.json"
  info "Validating catalog (.claude-plugin/marketplace.json)"

  if [ ! -f "$mk" ]; then
    err "catalog is missing: .claude-plugin/marketplace.json — run scripts/gen_catalog.sh"
    return
  fi
  if ! json_valid "$mk"; then
    err "catalog contains invalid JSON: .claude-plugin/marketplace.json"
    return
  fi

  local owner count ename esrc mname
  owner="$(jq -r '.owner.name // empty' "$mk")"
  [ -n "$owner" ] || err "catalog \"owner.name\" is required (set \"author.name\" in .claude-plugin/plugin.json)."

  count="$(jq -r 'if (.plugins|type)=="array" then (.plugins|length) else -1 end' "$mk")"
  if [ "$count" != 1 ]; then
    err "catalog must list exactly one plugin — this is a single-plugin repository (got: $count)."
    return
  fi

  ename="$(jq -r '.plugins[0].name // empty' "$mk")"
  esrc="$(jq -r '.plugins[0].source | if type=="string" then . else "@object" end' "$mk")"
  mname="$(jq -r '.name // empty' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
  [ "$ename" = "$mname" ] || err "catalog entry name \"$ename\" does not match plugin.json name \"$mname\"."
  [ "$esrc" = "./" ] || err "catalog entry \"source\" must be \"./\" (the repo root is the plugin; got: \"$esrc\")."

  # The catalog is generated — a stale one means plugin.json changed without a regen.
  if ! bash "$SCRIPT_DIR/gen_catalog.sh" --check >/dev/null 2>&1; then
    err "catalog is stale — run scripts/gen_catalog.sh and commit the result."
  fi
}

# --- Shared components (harness-agnostic) ------------------------------------
validate_components() {
  local f
  info "Validating components"

  # Skills: skills/<name>/SKILL.md require name + description.
  if [ -d "$ROOT/skills" ]; then
    while IFS= read -r f; do
      validate_frontmatter_file "$f" skill name description
    done < <(find "$ROOT/skills" -type f -name 'SKILL.md')
  fi

  # Agents: agents/*.md(/.mdc/.markdown) require name + description.
  if [ -d "$ROOT/agents" ]; then
    while IFS= read -r f; do
      validate_frontmatter_file "$f" agent name description
    done < <(find "$ROOT/agents" -type f \( -name '*.md' -o -name '*.mdc' -o -name '*.markdown' \))
  fi

  # Commands: commands/*.md(/.mdc/.markdown/.txt) require name + description
  # (name keeps the command portable to Cursor; Claude ignores the extra key).
  if [ -d "$ROOT/commands" ]; then
    while IFS= read -r f; do
      validate_frontmatter_file "$f" command name description
    done < <(find "$ROOT/commands" -type f \( -name '*.md' -o -name '*.mdc' -o -name '*.markdown' -o -name '*.txt' \))
  fi

  # Rules (Cursor-only component): rules/*.md(c) require description.
  if [ -d "$ROOT/rules" ]; then
    while IFS= read -r f; do
      validate_frontmatter_file "$f" rule description
    done < <(find "$ROOT/rules" -type f \( -name '*.md' -o -name '*.mdc' -o -name '*.markdown' \))
  fi

  # JSON config files must parse if present.
  for f in "$ROOT/marketplace.config.json" "$ROOT/.mcp.json" "$ROOT/mcp.json" "$ROOT/settings.json" "$ROOT/hooks/hooks.json" "$ROOT/.lsp.json" "$ROOT/.app.json"; do
    if [ -f "$f" ] && ! json_valid "$f"; then
      err "invalid JSON in $(rel "$f")"
    fi
  done

  # MCP servers are declared per harness: .mcp.json (Claude Code, Codex) vs mcp.json (Cursor).
  local has_dot=0 has_plain=0
  [ -f "$ROOT/.mcp.json" ] && json_valid "$ROOT/.mcp.json" && \
    [ "$(jq -r '(.mcpServers // {}) | length' "$ROOT/.mcp.json")" -gt 0 ] && has_dot=1
  [ -f "$ROOT/mcp.json" ] && json_valid "$ROOT/mcp.json" && \
    [ "$(jq -r '(.mcpServers // {}) | length' "$ROOT/mcp.json")" -gt 0 ] && has_plain=1
  [ "$has_dot" = 1 ] && [ "$has_plain" = 0 ] && \
    warn ".mcp.json declares MCP servers but mcp.json does not — Cursor will not see them."
  [ "$has_plain" = 1 ] && [ "$has_dot" = 0 ] && \
    warn "mcp.json declares MCP servers but .mcp.json does not — Claude Code and Codex will not see them."

  # A plugin should contribute at least one component.
  if [ ! -d "$ROOT/skills" ] && [ ! -d "$ROOT/commands" ] && [ ! -d "$ROOT/agents" ] && [ ! -d "$ROOT/rules" ]; then
    warn "no skills/, commands/, agents/, or rules/ directory — plugin contributes nothing."
  fi
}

# --- Main --------------------------------------------------------------------
echo "Validating plugin at: $ROOT"
echo

for platform in "${REQUIRED_PLATFORMS[@]}"; do
  validate_manifest "$platform" 1
done
validate_manifest_parity
validate_catalog
validate_components

# --- Summary -----------------------------------------------------------------
echo
if [ "$STRICT" = 1 ] && [ "$WARNINGS" -gt 0 ]; then
  ERRORS=$((ERRORS + WARNINGS))
fi

if [ "$ERRORS" -gt 0 ]; then
  printf '%sValidation failed: %d error(s), %d warning(s).%s\n' "$C_RED" "$ERRORS" "$WARNINGS" "$C_OFF" >&2
  exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
  printf '%sValidation passed with %d warning(s).%s\n' "$C_YEL" "$WARNINGS" "$C_OFF"
else
  printf '%sValidation passed.%s\n' "$C_GRN" "$C_OFF"
fi

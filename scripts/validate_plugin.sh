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
#     back at the repo root so Claude Code and Codex can install the plugin;
#   - a root package.json (the pi package manifest) whose name/version match and
#     whose "pi" key maps skills/ and commands/ for the pi coding agent;
#   - an opencode adapter, .opencode-plugin/ (package.json + index.js), whose
#     package name/version match the manifests above.
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

# --- opencode adapter (.opencode-plugin/) -----------------------------------
# opencode has no plugin manifest; it loads JS plugin modules. .opencode-plugin/
# holds a dependency-free adapter (index.js) whose config hook registers the shared
# skills/, commands/, agents/, and .mcp.json with opencode. Its package.json plays
# the manifest role: opencode uses "name" as the plugin id and "main" as the entry.
validate_opencode_plugin() {
  local dir=".opencode-plugin"
  local pkg="$ROOT/$dir/package.json"

  if [ ! -f "$pkg" ]; then
    err "missing opencode adapter ($dir/package.json) — the plugin must support every harness."
    return
  fi
  info "Validating opencode adapter ($dir/package.json)"
  if ! json_valid "$pkg"; then
    err "[opencode] $dir/package.json contains invalid JSON."
    return
  fi

  local name main field a b
  name="$(jq -r '.name // empty' "$pkg")"
  [[ "$name" =~ $PLUGIN_NAME_RE ]] || \
    err "[opencode] \"name\" must be lowercase alphanumerics/hyphens/periods (got: \"${name:-<missing>}\")."

  # Parity with the Claude manifest, like the other harness manifests.
  if json_valid "$ROOT/.claude-plugin/plugin.json" 2>/dev/null; then
    for field in name version; do
      a="$(jq -r --arg f "$field" '.[$f] // empty' "$ROOT/.claude-plugin/plugin.json")"
      b="$(jq -r --arg f "$field" '.[$f] // empty' "$pkg")"
      [ "$a" = "$b" ] || err "\"$field\" differs between manifests: claude=\"$a\" opencode=\"$b\"."
    done
    a="$(jq -r '.description // empty' "$ROOT/.claude-plugin/plugin.json")"
    b="$(jq -r '.description // empty' "$pkg")"
    [ "$a" = "$b" ] || warn "\"description\" differs between the claude manifest and $dir/package.json."
  fi

  # index.js uses import/export, so the package must be an ES module.
  [ "$(jq -r '.type // empty' "$pkg")" = module ] || err "[opencode] $dir/package.json must set \"type\": \"module\"."

  main="$(jq -r '.main // empty' "$pkg")"
  if [ -z "$main" ]; then
    err "[opencode] $dir/package.json needs \"main\" (the adapter entry, e.g. \"./index.js\")."
  elif ! is_safe_rel "$main"; then
    err "[opencode] \"main\" has invalid path \"$main\"."
  elif [ ! -f "$ROOT/$dir/$main" ]; then
    err "[opencode] \"main\" references missing file \"$dir/${main#./}\"."
  elif command -v node >/dev/null 2>&1; then
    # Syntax check only; the module is not executed. Skipped when node is absent.
    node --check "$ROOT/$dir/$main" 2>/dev/null || err "[opencode] $dir/${main#./} has a syntax error (node --check)."
  fi

  local comp
  for comp in skills commands agents rules hooks; do
    [ -e "$ROOT/$dir/$comp" ] && err "[opencode] $dir/$comp is inside the adapter directory — move it to the repo root."
  done

  # Remote install (`opencode plugin github:<owner>/<repo>`) installs the whole repo
  # as an npm package; opencode finds the server entry via the ROOT package.json's
  # exports["./server"]. (The root package.json is also the pi manifest.)
  local root_pkg="$ROOT/package.json" server
  if [ -f "$root_pkg" ] && json_valid "$root_pkg"; then
    server="$(jq -r '.exports["./server"] // empty | if type=="string" then . else (.import // .default // empty) end' "$root_pkg")"
    if [ -z "$server" ]; then
      warn "[opencode] package.json has no exports[\"./server\"] — \`opencode plugin github:<owner>/<repo>\` will not find the adapter (expected \"./$dir/${main#./}\")."
    elif [ -n "$main" ] && [ "${server#./}" != "$dir/${main#./}" ]; then
      err "[opencode] package.json exports[\"./server\"] is \"$server\" but the adapter entry is \"./$dir/${main#./}\"."
    fi
  fi
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

# --- pi package (package.json) -----------------------------------------------
# pi (earendil-works/pi) installs "pi packages": a directory, git repo, or npm package
# whose package.json has a "pi" key listing resource paths. The repo-root package.json
# is that manifest. It maps the shared components onto pi's resource types:
#   pi.skills  -> ./skills     (Agent Skills, loaded as-is)
#   pi.prompts -> ./commands   (Claude-style commands double as pi prompt templates)
# pi has no subagents or MCP, so agents/, rules/, and .mcp.json are not listed.
validate_pi_package() {
  local pkg="$ROOT/package.json"
  info "Validating pi package (package.json)"

  if [ ! -f "$pkg" ]; then
    err "missing pi manifest (package.json) — the plugin must support every harness."
    return
  fi
  if ! json_valid "$pkg"; then
    err "[pi] package.json contains invalid JSON."
    return
  fi

  # Parity with the Claude manifest, same rules as validate_manifest_parity.
  local base="$ROOT/.claude-plugin/plugin.json" field a b
  if json_valid "$base" 2>/dev/null; then
    for field in name version; do
      a="$(jq -r --arg f "$field" '.[$f] // empty' "$base")"
      b="$(jq -r --arg f "$field" '.[$f] // empty' "$pkg")"
      [ "$a" = "$b" ] || err "\"$field\" differs between manifests: claude=\"$a\" pi=\"$b\"."
    done
    a="$(jq -r '.description // empty' "$base")"
    b="$(jq -r '.description // empty' "$pkg")"
    [ "$a" = "$b" ] || warn "\"description\" differs between the claude and pi manifests."
  fi

  # "private": true would block the npm route (and the pi.dev gallery) for good.
  [ "$(jq -r '.private // false' "$pkg")" = true ] && \
    warn "[pi] package.json sets \"private\": true — it can never be published to npm."

  # The pi-package keyword lists an npm-published package in the pi.dev/packages gallery.
  jq -e '(.keywords // []) | index("pi-package")' "$pkg" >/dev/null 2>&1 || \
    warn "[pi] package.json \"keywords\" should include \"pi-package\" (pi.dev gallery discovery)."

  # Without a "pi" key pi falls back to auto-discovering skills/, prompts/, extensions/,
  # and themes/ — which would miss commands/. Require the explicit mapping.
  if ! jq -e '.pi | type == "object"' "$pkg" >/dev/null 2>&1; then
    err "[pi] package.json needs a \"pi\" object (e.g. {\"skills\": [\"./skills\"], \"prompts\": [\"./commands\"]})."
    return
  fi

  # Every listed path must exist. Entries may be globs or "!exclusions" — those are
  # skipped rather than expanded.
  local key val
  for key in skills prompts extensions themes; do
    while IFS= read -r val; do
      [ -n "$val" ] || continue
      case "$val" in '!'*|*'*'*|*'?'*|*'['*) continue ;; esac
      if ! is_safe_rel "$val" || [[ "$val" == http* ]]; then
        err "[pi] \"pi.$key\" has invalid path \"$val\"."
        continue
      fi
      [ -e "$ROOT/$val" ] || err "[pi] \"pi.$key\" references missing path \"$val\"."
    done < <(jq -r --arg k "$key" '.pi[$k] // empty | if type=="array" then .[] else . end | strings' "$pkg")
  done

  # Components pi would silently drop.
  if [ -d "$ROOT/skills" ] && ! jq -e '.pi.skills' "$pkg" >/dev/null 2>&1; then
    warn "[pi] skills/ exists but package.json \"pi.skills\" is not set — pi will not load them."
  fi
  if [ -d "$ROOT/commands" ] && ! jq -e '.pi.prompts' "$pkg" >/dev/null 2>&1; then
    warn "[pi] commands/ exists but package.json \"pi.prompts\" is not set — pi will not load them."
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
validate_opencode_plugin
validate_catalog
validate_pi_package
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

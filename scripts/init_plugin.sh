#!/usr/bin/env bash
#
# init_plugin.sh — Turn a fresh copy of the template into YOUR plugin.
#
# Run this once, right after creating a repository from the template. It:
#   1. writes the plugin name, display name, description, author, and version 0.1.0
#      into both manifests (.claude-plugin/plugin.json, .cursor-plugin/plugin.json),
#      and the category into marketplace.config.json;
#   2. replaces the template README.md with a starter README for the plugin;
#   3. regenerates the catalog (scripts/gen_catalog.sh);
#   4. runs the validator (scripts/validate_plugin.sh --strict);
#   5. deletes itself, so a later re-run can't clobber your README (use --keep to
#      keep it; git history has it either way).
#
# Requirements: bash (3.2+), jq.
#
# Usage:
#   scripts/init_plugin.sh <plugin-name> "<description>" [options]
#
#   <plugin-name>          kebab-case, e.g. doc-translator
#   <description>          one sentence: what the plugin does and WHEN to use it
#
#   --display-name <s>     human-readable name (default: title-cased plugin name)
#   --author <s>           author name   (default: git config user.name)
#   --email <s>            author email  (default: git config user.email)
#   --category <s>         catalog category (default: developer-tools)
#   --keep                 don't delete this script afterwards

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() { grep '^#' "${BASH_SOURCE[0]}" | sed '1d; s/^# \{0,1\}//'; }
die()   { echo "init_plugin.sh: $1" >&2; exit 2; }

NAME="" DESCRIPTION="" DISPLAY_NAME="" AUTHOR="" EMAIL="" CATEGORY="developer-tools" KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --display-name) DISPLAY_NAME="${2:-}"; shift 2 ;;
    --author)       AUTHOR="${2:-}"; shift 2 ;;
    --email)        EMAIL="${2:-}"; shift 2 ;;
    --category)     CATEGORY="${2:-}"; shift 2 ;;
    --keep)         KEEP=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             die "unknown option: $1" ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"
      elif [ -z "$DESCRIPTION" ]; then DESCRIPTION="$1"
      else die "unexpected argument: $1 (quote the description)"
      fi
      shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
[ -n "$NAME" ] && [ -n "$DESCRIPTION" ] || { usage >&2; exit 2; }
[[ "$NAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || \
  die "plugin name must be kebab-case (lowercase alphanumerics, hyphens, periods): \"$NAME\""

[ -n "$AUTHOR" ] || AUTHOR="$(git -C "$ROOT" config user.name 2>/dev/null || true)"
[ -n "$EMAIL" ]  || EMAIL="$(git -C "$ROOT" config user.email 2>/dev/null || true)"
[ -n "$AUTHOR" ] || die "no author — pass --author (git config user.name is unset)"
[ -n "$DISPLAY_NAME" ] || DISPLAY_NAME="$(printf '%s' "$NAME" | awk -F'[-.]' '{
  for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print }' OFS=' ')"

# --- 1. Manifests ------------------------------------------------------------
for manifest in "$ROOT/.claude-plugin/plugin.json" "$ROOT/.cursor-plugin/plugin.json"; do
  [ -f "$manifest" ] || die "missing $manifest"
  tmp="$(mktemp)"
  jq --arg name "$NAME" --arg display "$DISPLAY_NAME" --arg desc "$DESCRIPTION" \
     --arg author "$AUTHOR" --arg email "$EMAIL" '
    .name = $name
    | .displayName = $display
    | .version = "0.1.0"
    | .description = $desc
    | .author = ({name: $author} + (if $email != "" then {email: $email} else {} end))
    | .keywords = []' "$manifest" > "$tmp"
  mv "$tmp" "$manifest"
  echo "updated ${manifest#"$ROOT"/}"
done

tmp="$(mktemp)"
jq -n --arg category "$CATEGORY" '{category: $category}' > "$tmp"
mv "$tmp" "$ROOT/marketplace.config.json"
echo "updated marketplace.config.json"

# --- 2. README ---------------------------------------------------------------
# owner/repo from the origin remote, for the install instructions.
REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null \
  | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##' || true)"
[ -n "$REPO" ] || REPO="<owner>/<repo>"

cat > "$ROOT/README.md" <<EOF
# $DISPLAY_NAME

$DESCRIPTION

One source tree, installable in **Claude Code**, **Cursor**, and **Codex**.

## Components

| Type | Name | Purpose |
|------|------|---------|
| Skill | \`example-skill\` | _replace me_ |
| Command | \`/example-command\` | _replace me_ |
| Agent | \`example-agent\` | _replace me_ |

## Installation

### Claude Code

\`\`\`bash
claude plugin marketplace add $REPO
claude plugin install $NAME@$NAME
\`\`\`

### Cursor

Add this repository in Cursor's plugin settings — it reads
\`.cursor-plugin/plugin.json\` at the repo root.

### Codex

\`\`\`bash
codex plugin marketplace add $REPO
\`\`\`

Then install \`$NAME\` from the \`/plugins\` menu.

## Development

See [\`docs/develop_plugin.md\`](docs/develop_plugin.md). Before every commit:

\`\`\`bash
scripts/gen_catalog.sh               # after editing a plugin.json
scripts/validate_plugin.sh --strict
\`\`\`
EOF
echo "wrote README.md"

# --- 3 + 4. Catalog and validation -------------------------------------------
bash "$SCRIPT_DIR/gen_catalog.sh"
echo
bash "$SCRIPT_DIR/validate_plugin.sh" --strict

# --- 5. Self-remove ----------------------------------------------------------
if [ "$KEEP" = 0 ]; then
  rm -f "${BASH_SOURCE[0]}"
  echo
  echo "removed scripts/init_plugin.sh (one-shot; pass --keep next time to retain it)"
fi

cat <<EOF

$NAME is ready. Next:
  1. Replace the example components in skills/, commands/, and agents/.
  2. Add keywords to both plugin.json files, then run scripts/gen_catalog.sh.
  3. Add a LICENSE that matches the "license" field in the manifests.
  4. Commit.
EOF

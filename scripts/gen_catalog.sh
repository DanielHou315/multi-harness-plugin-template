#!/usr/bin/env bash
#
# gen_catalog.sh — Generate the single-plugin marketplace catalog.
#
# This repository IS one plugin: the plugin root is the repository root. Claude Code
# and Codex install plugins through a marketplace, so the repo also publishes a
# one-entry catalog at .claude-plugin/marketplace.json whose only plugin points back
# at the repo root ("source": "./"). Codex reads that same file; Cursor needs no
# catalog for a single-plugin repo.
#
# The catalog is a GENERATED ARTIFACT — do not edit it by hand. Everything in it is
# derived from .claude-plugin/plugin.json, plus the catalog-only fields in
# marketplace.config.json:
#   marketplace name/version/description  <- plugin name/version/description
#   marketplace owner                     <- plugin author
#   the single plugin entry               <- name, description, version, author,
#                                            keywords (+ source "./")
#   the entry's category                  <- marketplace.config.json ("category" is a
#                                            catalog field; Claude Code rejects it in
#                                            plugin.json)
# Missing fields are omitted.
#
# Requirements: bash, jq.
#
# Usage:
#   scripts/gen_catalog.sh            Write the catalog.
#   scripts/gen_catalog.sh --check    Don't write; exit 1 if the committed catalog
#                                      differs from freshly generated output (prints diff).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$ROOT/.claude-plugin/plugin.json"
CONFIG="$ROOT/marketplace.config.json"
OUT="$ROOT/.claude-plugin/marketplace.json"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

command -v jq >/dev/null 2>&1 || { echo "gen_catalog.sh: jq is required" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "gen_catalog.sh: missing $MANIFEST" >&2; exit 2; }
jq -e '.author.name // empty | length > 0' "$MANIFEST" >/dev/null 2>&1 || {
  echo "gen_catalog.sh: .claude-plugin/plugin.json needs \"author.name\" (it becomes the catalog owner)" >&2
  exit 2
}

config='{}'
if [ -f "$CONFIG" ]; then
  config="$(jq -c . "$CONFIG")" || { echo "gen_catalog.sh: invalid JSON in $CONFIG" >&2; exit 2; }
fi

generated="$(jq --argjson config "$config" '
  def compact: with_entries(select(.value != null));
  {
    "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
    name,
    version,
    description,
    owner: (.author | {name, email} | compact),
    plugins: [
      ({name, source: "./", description, version, author, category: $config.category, keywords} | compact)
    ]
  } | compact' "$MANIFEST")"

if [ "$CHECK" = 1 ]; then
  if ! diff -u <(cat "$OUT" 2>/dev/null) <(printf '%s\n' "$generated") >&2; then
    echo "Catalog out of date: .claude-plugin/marketplace.json — run scripts/gen_catalog.sh" >&2
    exit 1
  fi
else
  printf '%s\n' "$generated" > "$OUT"
  echo "wrote .claude-plugin/marketplace.json"
fi

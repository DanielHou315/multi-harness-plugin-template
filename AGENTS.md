# Agent instructions

This repository is **one agent plugin** that installs in Claude Code, Cursor, and
Codex from a single source tree. The repository root is the plugin root. Full
reference: [`docs/develop_plugin.md`](docs/develop_plugin.md).

## Rules

- **Components live at the repo root** — `skills/<name>/SKILL.md`,
  `commands/<name>.md`, `agents/<name>.md`, `rules/<name>.mdc` (Cursor only). Never
  put them inside a `.*-plugin/` directory; they are silently ignored there.
- **Every component file needs YAML frontmatter** with `name` and `description`
  (rules: `description` only). A skill's `description` must say *when* to invoke it.
- **Three manifests, kept parallel** — `.claude-plugin/plugin.json`,
  `.cursor-plugin/plugin.json`, and `.codex-plugin/plugin.json`. `name` and
  `version` must match; bump all three together. Codex puts display fields
  (`displayName`, `category`, …) under `interface`.
- **`package.json` is the pi manifest** — its `name`, `version`, and `description`
  track the other manifests; its `"pi"` key maps `skills` → `./skills` and
  `prompts` → `./commands`. Keep the `pi-package` keyword. Commands must stay
  plain Markdown + `$ARGUMENTS`/`$1` to work as pi prompt templates.
- **`.claude-plugin/marketplace.json` is generated** — never edit it. Change
  `.claude-plugin/plugin.json` (or `marketplace.config.json`, which holds the
  catalog-only `category`), then run `scripts/gen_catalog.sh`.
- **Reference bundled files through `${CLAUDE_PLUGIN_ROOT}`**, e.g.
  `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/foo.py"`. Never use absolute or `../` paths.
  Codex expands it only in hook commands; see the docs for MCP servers.
- **opencode loads the plugin through `.opencode-plugin/`** — a dependency-free
  adapter (`index.js`) that registers the root `skills/`, `commands/`, `agents/`,
  and `.mcp.json` at runtime. Don't copy components into it. Its `package.json`
  `name`/`version` must match the manifests; bump it with them. Only flat
  frontmatter keys carry over, and `model` only in `provider/model` form.
- **MCP servers go in two files** — `.mcp.json` (Claude Code, Codex) and `mcp.json`
  (Cursor), with the same servers.

## Before you finish

```bash
scripts/gen_catalog.sh               # if any plugin.json changed
scripts/validate_plugin.sh --strict  # must end with "Validation passed."
```

The task is not done until the validator exits 0.

# Developing the plugin

This repository is **one plugin** published to **three harnesses — Claude Code,
Cursor, and Codex** — from a single source tree. The repository root *is* the plugin
root: components sit at the top level, and each harness finds them through its own
manifest. This guide is the canonical structure reference; `AGENTS.md` is the short
version for coding agents.

## Repository layout

```
<plugin-repo>/
├── .claude-plugin/
│   ├── plugin.json            # Claude Code manifest (Codex falls back to it)
│   └── marketplace.json       # one-entry catalog — GENERATED, do not edit
├── .cursor-plugin/
│   └── plugin.json            # Cursor manifest
├── marketplace.config.json    # catalog-only fields (category)
├── skills/<name>/
│   ├── SKILL.md               # model-invoked skill
│   └── references/*.md        # optional files the skill bundles
├── commands/<name>.md         # slash commands
├── agents/<name>.md           # subagents
├── scripts/
│   ├── gen_catalog.sh         # regenerates the catalog
│   ├── validate_plugin.sh     # the validator (CI + local)
│   └── *                      # your own helper scripts (see ${CLAUDE_PLUGIN_ROOT})
├── docs/develop_plugin.md     # this file
├── AGENTS.md / CLAUDE.md      # instructions for agents working on the plugin
└── .github/workflows/validate.yml
```

## How each harness loads the plugin

| | Claude Code | Cursor | Codex |
|---|---|---|---|
| Manifest | `.claude-plugin/plugin.json` | `.cursor-plugin/plugin.json` | `.codex-plugin/plugin.json` if present, else the Claude manifest |
| Installed via | catalog: `.claude-plugin/marketplace.json` | the repo itself (single-plugin repo) | the same Claude catalog |
| Components | `skills/`, `commands/`, `agents/` | same, plus `rules/*.mdc` | `skills/` (plus hooks and MCP) |
| MCP config | `.mcp.json` | `mcp.json` | `.mcp.json` |

Because components are shared, a conformant plugin needs only:

1. **Both manifests** (`.claude-plugin/plugin.json` + `.cursor-plugin/plugin.json`)
   with matching `name` and `version`.
2. Components at the **repo root** (never inside the `.*-plugin/` dirs).
3. An up-to-date generated catalog.

Codex needs nothing of its own: it reads the Claude catalog, resolves
`"source": "./"` to the repo root, and falls back to the Claude manifest. Add a
`.codex-plugin/plugin.json` only if you want Codex-specific presentation metadata;
the validator then holds its `name` and `version` to the same parity rule.

## The catalog is a generated artifact

Claude Code and Codex install plugins through a marketplace, so the repo publishes a
catalog with exactly one entry that points back at the repo root:

```json
{
  "name": "doc-translator",
  "owner": { "name": "Your Name" },
  "plugins": [{ "name": "doc-translator", "source": "./", "...": "..." }]
}
```

`scripts/gen_catalog.sh` derives the file from `.claude-plugin/plugin.json` — the
marketplace takes the plugin's `name`, `version`, and `description`, the `owner` is
the plugin's `author`, and the entry copies `description`, `version`, `author`, and
`keywords`. The entry's `category` comes from `marketplace.config.json`, because
`category` is a catalog field: `claude plugin validate --strict` rejects it inside
`plugin.json`. **Never edit the catalog by hand**; edit `plugin.json` (or
`marketplace.config.json`) and regenerate. The validator (and therefore CI) fails
if the committed catalog is stale.

```bash
scripts/gen_catalog.sh            # rewrite the catalog
scripts/gen_catalog.sh --check    # fail (with a diff) if it is stale
```

Users install with `<plugin>@<marketplace>`, and both are the plugin name:
`claude plugin install doc-translator@doc-translator`.

To *also* list the plugin in a separate multi-plugin marketplace, add an entry there
with a remote source (`{"source": "github", "repo": "<owner>/<repo>"}`) — nothing in
this repo needs to change.

## Manifest schema (`plugin.json`)

Only `name` is strictly required, but keep both manifests parallel:

```json
{
  "name": "doc-translator",
  "displayName": "Doc Translator",
  "version": "0.1.0",
  "description": "What it does and when to use it.",
  "author": { "name": "Your Name", "email": "you@example.com" },
  "license": "MIT",
  "keywords": ["docs", "translation"]
}
```

- `name` is kebab-case (lowercase alphanumerics, hyphens, periods).
- `author.name` is required here because it becomes the catalog `owner`.
- `category` does **not** go here — set it in `marketplace.config.json`.
- The Claude manifest also carries `$schema`
  (`https://json.schemastore.org/claude-code-plugin-manifest.json`). The Cursor
  manifest may carry an optional `logo` (a relative path that must exist).
- Bump `version` in **both** manifests on every release, then regenerate the
  catalog — installed copies only update when the version changes.

## Component frontmatter

The validator requires YAML frontmatter on every component file:

| Component | Path                     | Required keys          |
|-----------|--------------------------|------------------------|
| Skill     | `skills/<name>/SKILL.md` | `name`, `description`  |
| Command   | `commands/<name>.md`     | `name`, `description`  |
| Agent     | `agents/<name>.md`       | `name`, `description`  |
| Rule (Cursor) | `rules/<name>.mdc`   | `description`          |

A skill's `description` should state **when** the agent should invoke it — that
text is what triggers the skill. Skills are the most portable component (all three
harnesses load them), so put the real logic in a skill and keep commands as thin
entry points that defer to it.

## Bundled scripts and supporting files

Components can ship more than their entry file:

- **Skill reference files** — a skill may bundle supporting docs alongside its
  `SKILL.md` (e.g. `skills/<name>/references/*.md`) and point to them from the
  skill body.
- **Helper scripts** — carry executables under `scripts/` and invoke them from a
  skill, command, or hook using the `${CLAUDE_PLUGIN_ROOT}` path prefix (e.g.
  `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/scan_docs.py"`), which resolves to the
  installed plugin root. Installed plugins are copied to a cache, so absolute paths
  and `../` paths break.

## Optional config files

| File | Purpose |
|------|---------|
| `.mcp.json` / `mcp.json` | MCP servers — Claude Code and Codex read `.mcp.json`, Cursor reads `mcp.json`. Ship both with the same servers; the validator warns if only one declares any. |
| `hooks/hooks.json` | Lifecycle hooks. Event names and schema differ per harness — check each harness's docs before relying on one file for all three. |
| `settings.json` | Claude Code default settings for the plugin. |
| `.lsp.json` | Claude Code language-server config. |
| `rules/*.mdc` | Cursor rules. |
| `assets/` | Images, e.g. the Cursor manifest's `logo`. |

The validator only checks these are valid JSON and that any path referenced from a
manifest exists — it does **not** police their schemas. See the documentation
linked at the end.

## Validation

The validator mirrors the official Cursor template validator
(`fieldsphere/cursor-team-marketplace-template`) and applies the same rules to the
Claude manifest. It needs `bash` and `jq`.

```bash
scripts/validate_plugin.sh            # report errors + warnings
scripts/validate_plugin.sh --strict   # treat warnings as errors (used in CI)
```

It checks:

- both manifests exist, are valid JSON, and have a well-formed `name`;
- `name` and `version` match across manifests (`description` mismatch is a warning);
- referenced path fields (`logo`, `skills`, `agents`, `commands`, `hooks`, …) exist;
- no component directory is hiding inside `.claude-plugin/` or `.cursor-plugin/`;
- the catalog has an owner, exactly one entry, the right name, `"source": "./"`,
  and is not stale;
- component frontmatter has the required keys;
- config files parse, and MCP servers are declared for every harness.

CI runs `scripts/validate_plugin.sh --strict` on every pull request and on every
push to `main` (`.github/workflows/validate.yml`).

If you have the `claude` CLI installed, additionally run the official checker:

```bash
claude plugin validate . --strict
```

## Trying it locally

```bash
# Claude Code — load straight from the working tree, no install
claude --plugin-dir .

# Claude Code — exercise the real install path
claude plugin marketplace add .
claude plugin install <name>@<name>

# Codex
codex plugin marketplace add .
```

In Cursor, add the local folder (or the pushed repository) in the plugin settings.

## Documentation

- [Claude Code plugin reference](https://code.claude.com/docs/en/plugins-reference)
- [Claude Code marketplaces](https://code.claude.com/docs/en/plugin-marketplaces)
- [Cursor plugins](https://cursor.com/docs/plugins/building)
- [Codex plugins](https://developers.openai.com/codex/plugins/build)

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
│   ├── plugin.json            # Claude Code manifest
│   └── marketplace.json       # one-entry catalog — GENERATED, do not edit
├── .cursor-plugin/
│   └── plugin.json            # Cursor manifest
├── .codex-plugin/
│   └── plugin.json            # Codex manifest
├── .opencode-plugin/
│   ├── package.json           # opencode adapter identity (name/version parity)
│   └── index.js               # opencode adapter — registers the shared components
├── marketplace.config.json    # catalog-only fields (category)
├── package.json               # pi package manifest ("pi" key)
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
| Manifest | `.claude-plugin/plugin.json` | `.cursor-plugin/plugin.json` | `.codex-plugin/plugin.json` |
| Installed via | catalog: `.claude-plugin/marketplace.json` | the repo itself (single-plugin repo) | the same Claude catalog |
| Components | `skills/`, `commands/`, `agents/` | same, plus `rules/*.mdc` | `skills/` (plus hooks and MCP) |
| MCP config | `.mcp.json` | `mcp.json` | `.mcp.json` |

Because components are shared, a conformant plugin needs only:

1. **All three manifests** (`.claude-plugin/`, `.cursor-plugin/`, `.codex-plugin/`)
   with matching `name` and `version`.
2. Components at the **repo root** (never inside the `.*-plugin/` dirs).
3. An up-to-date generated catalog.

Codex installs from the same Claude catalog and resolves `"source": "./"` to the
repo root. It would fall back to the Claude manifest if `.codex-plugin/plugin.json`
were missing, but the native manifest is required here: it names the component
paths Codex loads (`"skills": "./skills/"`) and carries the `interface` block Codex
uses to present the plugin.

### pi (`package.json`)

[pi](https://github.com/earendil-works/pi) (`@earendil-works/pi-coding-agent`)
installs *pi packages*: a local directory, a git repository, or an npm package whose
`package.json` carries a `"pi"` key listing resource paths. The repo-root
`package.json` is that manifest, so the repo installs straight from GitHub:

```bash
pi install git:github.com/<owner>/<repo>          # or @<tag|commit> to pin
pi install ./path/to/checkout                     # local, loaded in place
```

| Shared component | pi resource | Notes |
|---|---|---|
| `skills/<name>/SKILL.md` | skill (`pi.skills`) | pi implements the Agent Skills spec; also invocable as `/skill:<name>`. |
| `commands/<name>.md` | prompt template (`pi.prompts`) | Filename is the command name; pi reads `description` and `argument-hint`, ignores `name`, and substitutes `$ARGUMENTS`, `$@`, `$1`, `${1:-default}`. |
| `agents/<name>.md` | — | pi has no subagent concept. |
| `.mcp.json` / `mcp.json` | — | pi has no built-in MCP client (community adapters exist). |
| `rules/*.mdc` | — | Cursor only. |

The `"pi"` key is required: without it pi auto-discovers only `skills/`,
`prompts/`, `extensions/`, and `themes/`, and would miss `commands/`. Paths are
relative to the repo root and may be globs or `!exclusions`. To add pi-only
resources later, create e.g. `extensions/*.ts` or `themes/*.json` and list them
under `pi.extensions` / `pi.themes`.

Keep the `pi-package` keyword: if you ever publish to npm, it lists the package in
the [pi.dev/packages](https://pi.dev/packages) gallery (`pi install npm:<name>`).
Do not set `"private": true`. Publishing is optional — git installs need nothing more.

Portability caveats for pi:

- `${CLAUDE_PLUGIN_ROOT}` is **not** expanded in skills or prompt templates. pi
  tells the model where a skill lives, so reference bundled files by paths
  relative to the skill directory.
- Claude-only command features — `allowed-tools`, `` !`bash` `` pre-execution,
  `@file` references — are passed through as plain text by pi.

### opencode

opencode has no plugin marketplace and no manifest for a skills/commands/agents
bundle — an opencode plugin is a JS module listed under `"plugin"` in
`opencode.json` (an npm package or a local path). So instead of a fourth manifest
the repo ships a thin adapter in `.opencode-plugin/`:

- `package.json` — `name`, `version`, `description`, `author`, `license`,
  `keywords`, plus `"type": "module"` and `"main": "./index.js"`. `name` is the
  opencode plugin id. Keep `name`/`version` identical to the three manifests
  (`init_plugin.sh` sets them; the validator checks them).
- `index.js` — a dependency-free module whose `config` hook runs before opencode
  resolves anything and points it at the shared tree. Nothing is copied or
  generated, so there is nothing to go stale:

| Shared component | Becomes in opencode | Carried over |
|---|---|---|
| `skills/<name>/SKILL.md` | an entry in `skills.paths` (opencode reads `SKILL.md` natively) | everything |
| `commands/<name>.md` | `command.<name>`, body as `template` (`$ARGUMENTS`, `$1` work) | `description`, `agent`, `subtask`, `model` if `provider/model` |
| `agents/<name>.md` | `agent.<name>`, body as `prompt` | `description`, `mode` (default `subagent`), `temperature`, `model` if `provider/model` |
| `.mcp.json` `mcpServers` | `mcp.<name>` — stdio → `local`, `http`/`sse` → `remote` | `command`+`args`, `env`, `cwd` (relative to the plugin root), `url`, `headers` |

The command/agent name is the frontmatter `name` (falling back to the file name).
Only flat `key: value` frontmatter is read; Claude-only keys (`allowed-tools`,
`tools`, `argument-hint`, `model: sonnet`) are dropped. In `.mcp.json` values the
adapter expands `${CLAUDE_PLUGIN_ROOT}` / `${PLUGIN_ROOT}` to the plugin root and
`${VAR}` / `${VAR:-default}` from the environment, as Claude Code does. Anything
the user already defines under the same name in their own opencode config wins.

opencode installs `"plugin"` entries with npm, so a git spec installs the whole
repo as a package. The repo-root `package.json` (shared with pi) points opencode
at the adapter through `"exports": {"./server": "./.opencode-plugin/index.js"}`;
opencode prefers `exports["./server"]` over `main`, and pi ignores both. The
adapter then finds `skills/`, `commands/`, … next to itself inside the installed
package:

```bash
opencode plugin -g github:<owner>/<repo>          # or #<tag|commit> to pin
```

`opencode plugin -g` adds the spec to the global opencode config
(`~/.config/opencode/opencode.json[c]`); without `-g` it goes into the current
project's config. Writing `"plugin": ["github:<owner>/<repo>"]` by hand is
equivalent; opencode installs it on the next start into
`~/.cache/opencode/packages/`. Keep the root `package.json` free of `"private": true`
and of a `files` list that would drop `.opencode-plugin/` or the components.

From a local clone (e.g. for development), point opencode at the adapter
directory: `opencode plugin -g <clone>/.opencode-plugin`. A path entry in
`"plugin"` or a symlink to `index.js` in `~/.config/opencode/plugins/` works too. For skills only, skip the
adapter: `"skills": {"paths": ["~/.local/share/opencode-plugins/<name>/skills"]}`.

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

Only `name` is strictly required, but keep all three manifests parallel:

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
- Bump `version` in **all three** manifests on every release, then regenerate the
  catalog — installed copies only update when the version changes.

### Codex manifest (`.codex-plugin/plugin.json`)

Codex shares `name`, `version`, `description`, `author`, `license`, and `keywords`,
but points at component paths explicitly and moves presentation fields under
`interface` (it has no top-level `displayName`):

```json
{
  "name": "doc-translator",
  "version": "0.1.0",
  "description": "What it does and when to use it.",
  "author": { "name": "Your Name", "email": "you@example.com" },
  "license": "MIT",
  "keywords": ["docs", "translation"],
  "skills": "./skills/",
  "interface": {
    "displayName": "Doc Translator",
    "shortDescription": "Translate Markdown docs",
    "developerName": "Your Name",
    "category": "Productivity"
  }
}
```

- Codex loads `skills/`, `.mcp.json`, and `hooks/hooks.json` from their default
  paths. A path field **replaces** its default rather than adding to it, and must
  start with `./`.
- Codex does not load `commands/` or `agents/`, so keep the real logic in skills.
- `interface` also accepts `longDescription`, `websiteURL`, `defaultPrompt` (a
  list of starter prompts), `brandColor`, and `logo` / `composerIcon` (relative
  image paths, checked by the validator).

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

  Codex sets `CLAUDE_PLUGIN_ROOT` (and `PLUGIN_ROOT`) only for **hook** commands. It
  does not substitute it in `SKILL.md` text or in `.mcp.json`. For an MCP server that
  must run under Codex too, set `"cwd": "."` and use paths relative to the plugin root.

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

- all three manifests exist, are valid JSON, and have a well-formed `name`;
- `name` and `version` match across manifests (`description` mismatch is a warning);
- referenced path fields (`logo`, `skills`, `agents`, `commands`, `hooks`, `apps`,
  Codex `interface.logo`, …) exist;
- no component directory is hiding inside a `.*-plugin/` directory;
- the catalog has an owner, exactly one entry, the right name, `"source": "./"`,
  and is not stale;
- component frontmatter has the required keys;
- config files parse, and MCP servers are declared for every harness;
- `package.json` exists, matches the Claude manifest's `name` and `version`, has a
  `"pi"` object whose listed paths exist, maps `skills/` and `commands/`, carries
  the `pi-package` keyword, and is not `"private": true`;
- the opencode adapter's `package.json` exists, matches the manifests' `name` and
  `version`, is `"type": "module"`, and its `main` exists (and passes
  `node --check` when `node` is installed); the root `package.json` maps
  `exports["./server"]` to that entry, so `opencode plugin github:…` works.

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
codex plugin add <name>@<name>
codex exec "Which skills from the <name> plugin can you use?"   # smoke test
```

In Cursor, add the local folder (or the pushed repository) in the plugin settings.

```bash
# pi — installs into ~/.pi/agent/settings.json (add -l for .pi/settings.json)
pi install .
pi list
pi remove .
```

For a check that makes no LLM call, ask pi's RPC mode which commands it resolved;
the skill appears as `skill:<name>` and each command as a `prompt`:

```bash
echo '{"type":"get_commands"}' | pi --mode rpc --no-session | jq '.data.commands[] | {name, source}'
```

```bash
# opencode — register the working tree for one scratch project, then inspect
# what opencode resolved (no model calls needed)
cd "$(mktemp -d)" && git init -q
echo '{"plugin": ["<path-to-repo>/.opencode-plugin"]}' > opencode.json
opencode debug skill                          # lists <skill> from skills/
opencode debug config | jq '.command, .mcp'   # commands and MCP servers
opencode agent list | grep subagent           # agents
opencode mcp list                             # MCP servers connect
```

## Documentation

- [Claude Code plugin reference](https://code.claude.com/docs/en/plugins-reference)
- [Claude Code marketplaces](https://code.claude.com/docs/en/plugin-marketplaces)
- [Cursor plugins](https://cursor.com/docs/plugins/building)
- [Codex plugins](https://developers.openai.com/codex/plugins/build)
- [pi packages](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/packages.md),
  [skills](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md),
  [prompt templates](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/prompt-templates.md)
- [opencode plugins](https://opencode.ai/docs/plugins/) and [config](https://opencode.ai/docs/config/)

# multi-harness-plugin-template

[![Validate plugin](https://github.com/DanielHou315/multi-harness-plugin-template/actions/workflows/validate.yml/badge.svg)](https://github.com/DanielHou315/multi-harness-plugin-template/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Use this template](https://img.shields.io/badge/-Use%20this%20template-2ea44f?logo=github)](https://github.com/DanielHou315/multi-harness-plugin-template/generate)

**A Claude Code plugin template that also ships as a Cursor plugin, a Codex plugin,
a pi package, and an opencode plugin — from one source tree.** Write your
[Agent Skills](https://agentskills.io) (`SKILL.md`), slash commands, subagents, and
MCP servers once; the repo is its own one-plugin marketplace, and a validator in CI
keeps the manifests in sync.

The repository root *is* the plugin: shared components (`skills/`, `commands/`,
`agents/`) sit at the top level, a small manifest per harness describes them, and a
generated one-entry catalog makes the repo installable as a marketplace.
One repository, one plugin — create a new repository from this template for each
plugin you build.

### Supported harnesses

| Harness | Manifest | Loads | Install from |
|---|---|---|---|
| Claude Code | `.claude-plugin/plugin.json` | skills, commands, agents, hooks, `.mcp.json` | the repo as a marketplace |
| Cursor | `.cursor-plugin/plugin.json` | skills, commands, agents, `rules/*.mdc`, `mcp.json` | the repo |
| Codex | `.codex-plugin/plugin.json` | skills, hooks, `.mcp.json` | the same marketplace |
| [pi](https://github.com/earendil-works/pi) | `package.json` (`"pi"` key) | skills, commands (as prompt templates) | `pi install git:…` |
| [opencode](https://opencode.ai) | `.opencode-plugin/` adapter | skills, commands, agents, `.mcp.json` | a local clone |

Exact install commands and per-harness caveats are in
[How one tree serves three harnesses](#how-one-tree-serves-three-harnesses),
[pi](#pi), and [opencode](#opencode) below.

## Quick start

1. Click **Use this template** on GitHub (or
   `gh repo create my-plugin --template DanielHou315/multi-harness-plugin-template --private --clone`).
2. Initialise it — this renames the plugin in both manifests, writes a starter
   README over this one, regenerates the catalog, validates, and then removes itself:

   ```bash
   scripts/init_plugin.sh doc-translator "Translate Markdown docs between languages. Use when asked to translate or localise documentation."
   ```

   Author name and email default to your `git config`; see
   `scripts/init_plugin.sh --help` for `--display-name`, `--author`, `--email`,
   `--category`, and `--keep`.
3. Replace the example components with real ones and commit.

Requires `bash` and [`jq`](https://jqlang.github.io/jq/).

## What's in the box

```
├── .claude-plugin/
│   ├── plugin.json            # Claude Code manifest
│   └── marketplace.json       # one-entry catalog — GENERATED, do not edit
├── .cursor-plugin/plugin.json # Cursor manifest
├── .codex-plugin/plugin.json  # Codex manifest
├── .opencode-plugin/          # opencode adapter (package.json + index.js)
├── marketplace.config.json    # catalog-only fields (category)
├── package.json               # pi package manifest ("pi" key)
├── skills/example-skill/SKILL.md
├── commands/example-command.md
├── agents/example-agent.md
├── scripts/
│   ├── init_plugin.sh         # one-shot: template -> your plugin
│   ├── gen_catalog.sh         # regenerates the catalog from plugin.json
│   └── validate_plugin.sh     # the validator (CI + local)
├── docs/develop_plugin.md     # full structure reference
├── AGENTS.md / CLAUDE.md      # rules for coding agents working on the plugin
└── .github/workflows/validate.yml
```

## How one tree serves three harnesses

| | Claude Code | Cursor | Codex |
|---|---|---|---|
| Manifest | `.claude-plugin/plugin.json` | `.cursor-plugin/plugin.json` | `.codex-plugin/plugin.json` |
| Installed via | `.claude-plugin/marketplace.json` (`"source": "./"`) | the repo itself | the same Claude catalog |
| Install | `claude plugin marketplace add <owner>/<repo>` then `claude plugin install <name>@<name>` | add the repo in plugin settings | `codex plugin marketplace add <owner>/<repo>` then `codex plugin add <name>@<name>` |

### pi

| | pi coding agent |
|---|---|
| Manifest | `package.json` (the `"pi"` key) |
| Installed via | the repo itself as a pi package (git, npm, or local path) |
| Install | `pi install git:github.com/<owner>/<repo>` (append `@<ref>` to pin) |
| Loads | `skills/` as skills; `commands/*.md` as prompt templates (`/example-command`) |
| Not loaded | `agents/` (no subagents), `rules/`, `.mcp.json` (no built-in MCP) |

### opencode

| | opencode |
|---|---|
| Manifest | `.opencode-plugin/package.json` (plugin id = `name`) + `index.js` adapter |
| Installed via | a clone of the repo; the adapter's `config` hook registers the shared tree |
| Install | `git clone https://github.com/<owner>/<repo> <dir>` then `opencode plugin -g <dir>/.opencode-plugin` |
| Loads | `skills/` (via `skills.paths`), `commands/*.md` as commands, `agents/*.md` as subagents, `.mcp.json` servers |
| Not loaded | `rules/`, `hooks/`; Claude-only frontmatter (`allowed-tools`, `tools`, `model: sonnet`) |

`git pull` in the clone to update. Skills-only alternative, no adapter:
`"skills": {"paths": ["<dir>/skills"]}` in `opencode.json`.

## Day-to-day

```bash
scripts/gen_catalog.sh               # after editing a plugin.json or marketplace.config.json
scripts/validate_plugin.sh --strict  # before every commit; CI runs the same
claude plugin validate . --strict    # optional, official Claude Code checker
claude --plugin-dir .                # try the plugin without installing it
```

See [`docs/develop_plugin.md`](docs/develop_plugin.md) for manifest fields,
component frontmatter, optional config files (MCP, hooks, rules), and everything
the validator checks.

## Contributing

Direct pushes to `main` are not accepted. Fork the repository, make your change on
a branch in your fork, and open a pull request against `main`. CI must pass
(`scripts/validate_plugin.sh --strict`) before a PR can be merged.

## FAQ

### How do I make a Claude Code plugin that also works in Cursor and Codex?

Create a repository from this template and run `scripts/init_plugin.sh`. All three
harnesses read the same `skills/`, `commands/`, and `agents/` directories; each
only needs its own small manifest (`.claude-plugin/`, `.cursor-plugin/`,
`.codex-plugin/`), which the init script fills in and the validator keeps in sync.
Codex installs from the same `marketplace.json` as Claude Code.

### Can I publish Agent Skills (`SKILL.md`) this way without writing a full plugin?

Yes. A plugin with only a `skills/` directory is valid — delete the example command
and agent. The skills load in every harness above, including pi and opencode.

### Do I need a separate marketplace repository?

No. `scripts/gen_catalog.sh` generates a one-entry `.claude-plugin/marketplace.json`
pointing at the repo root (`"source": "./"`), so `claude plugin marketplace add
<owner>/<repo>` (or `codex plugin marketplace add`) works on the plugin repo itself.

### How do I add an MCP server?

Declare it in `.mcp.json` (Claude Code, Codex, opencode) and the same servers in
`mcp.json` (Cursor). See [`docs/develop_plugin.md`](docs/develop_plugin.md) for
`${CLAUDE_PLUGIN_ROOT}` handling in each harness. pi has no built-in MCP support.

### How do I keep the manifests from drifting?

Run `scripts/validate_plugin.sh --strict` before committing; the included GitHub
Actions workflow runs it on every pull request. It checks name/version parity across
all manifests, frontmatter on every component, and that the catalog isn't stale.

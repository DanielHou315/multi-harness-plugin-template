# multi-harness-plugin-template

A template for building **one** agent plugin that installs in **Claude Code**,
**Cursor**, and **Codex** from a single source tree.

The repository root *is* the plugin: shared components (`skills/`, `commands/`,
`agents/`) sit at the top level, two small manifests describe them to each harness,
and a generated one-entry catalog makes the repo installable as a marketplace.
One repository, one plugin — create a new repository from this template for each
plugin you build.

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
│   ├── plugin.json            # Claude Code manifest (Codex falls back to it)
│   └── marketplace.json       # one-entry catalog — GENERATED, do not edit
├── .cursor-plugin/plugin.json # Cursor manifest
├── marketplace.config.json    # catalog-only fields (category)
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
| Manifest | `.claude-plugin/plugin.json` | `.cursor-plugin/plugin.json` | falls back to the Claude manifest |
| Installed via | `.claude-plugin/marketplace.json` (`"source": "./"`) | the repo itself | the same Claude catalog |
| Install | `claude plugin marketplace add <owner>/<repo>` then `claude plugin install <name>@<name>` | add the repo in plugin settings | `codex plugin marketplace add <owner>/<repo>` then `/plugins` |

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

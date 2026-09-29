// .opencode-plugin/index.js — opencode adapter for this plugin.
//
// opencode (https://opencode.ai) has no plugin marketplace and no manifest format
// for skills/commands/agents bundles; its plugins are JS modules. This module is a
// thin, dependency-free adapter: when opencode loads it, its `config` hook points
// opencode at the SAME shared components the other harnesses use, so nothing is
// duplicated or generated:
//
//   skills/<name>/SKILL.md  -> appended to config.skills.paths (opencode reads
//                              SKILL.md natively; nothing is translated)
//   commands/<name>.md      -> config.command[<name>]  (body = template; $ARGUMENTS
//                              works as in Claude Code)
//   agents/<name>.md        -> config.agent[<name>]    (mode "subagent"; body = prompt)
//   .mcp.json mcpServers    -> config.mcp[<name>]      (stdio -> "local",
//                              http/sse -> "remote")
//
// Only portable frontmatter keys are carried over (see pickCommand / pickAgent).
// Claude-only keys such as `allowed-tools`, `tools`, or a short `model: sonnet`
// alias are dropped, because opencode would reject or misread them.
// Entries the user already defined in their own opencode config win: this adapter
// never overwrites an existing command, agent, or MCP server of the same name.
//
// The plugin id is read from ./package.json, whose name/version must match the
// other three manifests (scripts/validate_plugin.sh checks this).
//
// Tested against opencode 1.18.x (v1 plugin API: default export { id, server }).

import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

// Resolve symlinks so the adapter still finds the repo when it is symlinked into
// ~/.config/opencode/plugins/ or .opencode/plugins/.
const HERE = path.dirname(fs.realpathSync(fileURLToPath(import.meta.url)))
const ROOT = path.dirname(HERE) // the repository root is the plugin root
const PKG = JSON.parse(fs.readFileSync(path.join(HERE, "package.json"), "utf8"))

// --- helpers -------------------------------------------------------------------

// Parse the leading `---` YAML frontmatter block. Only flat `key: value` scalars
// are understood (strings, numbers, booleans) — enough for the portable keys this
// adapter reads. Anything nested is ignored.
function parseMarkdown(file) {
  const text = fs.readFileSync(file, "utf8").replace(/^﻿/, "")
  const match = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(text)
  if (!match) return { data: {}, body: text.trim() }
  const data = {}
  for (const line of match[1].split(/\r?\n/)) {
    const kv = /^([A-Za-z0-9_-]+)[ \t]*:[ \t]*(.*?)[ \t]*$/.exec(line)
    if (!kv || kv[2] === "") continue
    let value = kv[2]
    if (/^(["']).*\1$/.test(value)) value = value.slice(1, -1)
    else if (value === "true" || value === "false") value = value === "true"
    else if (/^-?\d+(\.\d+)?$/.test(value)) value = Number(value)
    data[kv[1]] = value
  }
  return { data, body: text.slice(match[0].length).trim() }
}

// Markdown component files in a root-level directory, sorted for determinism.
function markdownFiles(dir) {
  const abs = path.join(ROOT, dir)
  if (!fs.existsSync(abs)) return []
  return fs
    .readdirSync(abs, { withFileTypes: true })
    .filter((e) => e.isFile() && /\.(md|markdown)$/.test(e.name))
    .map((e) => path.join(abs, e.name))
    .sort()
}

function componentName(file, data) {
  return typeof data.name === "string" && data.name ? data.name : path.basename(file).replace(/\.[^.]+$/, "")
}

// opencode models are "provider/model"; Claude aliases like "sonnet" are dropped.
function portableModel(model) {
  return typeof model === "string" && model.includes("/") ? model : undefined
}

function compact(obj) {
  return Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== undefined))
}

// Expand ${CLAUDE_PLUGIN_ROOT} / ${PLUGIN_ROOT} to the repo root and ${VAR} /
// ${VAR:-default} from the environment, mirroring Claude Code's .mcp.json rules.
function expand(value) {
  if (typeof value !== "string") return value
  return value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g, (_, name, fallback) => {
    if (name === "CLAUDE_PLUGIN_ROOT" || name === "PLUGIN_ROOT") return ROOT
    return process.env[name] ?? fallback ?? ""
  })
}

function expandRecord(record) {
  if (!record || typeof record !== "object") return undefined
  return Object.fromEntries(Object.entries(record).map(([k, v]) => [k, expand(String(v))]))
}

// --- component mapping ---------------------------------------------------------

function pickCommand(data, body) {
  return compact({
    template: body,
    description: typeof data.description === "string" ? data.description : undefined,
    agent: typeof data.agent === "string" ? data.agent : undefined,
    model: portableModel(data.model),
    subtask: typeof data.subtask === "boolean" ? data.subtask : undefined,
  })
}

function pickAgent(data, body) {
  return compact({
    prompt: body,
    description: typeof data.description === "string" ? data.description : undefined,
    mode: ["subagent", "primary", "all"].includes(data.mode) ? data.mode : "subagent",
    model: portableModel(data.model),
    temperature: typeof data.temperature === "number" ? data.temperature : undefined,
  })
}

// Claude Code / Codex .mcp.json server -> opencode "local" / "remote" server.
function toOpencodeMcp(server) {
  if (!server || typeof server !== "object") return undefined
  const type = server.type ?? (server.url ? "http" : "stdio")
  if (type === "http" || type === "sse" || type === "streamable-http") {
    if (typeof server.url !== "string") return undefined
    return compact({ type: "remote", url: expand(server.url), headers: expandRecord(server.headers) })
  }
  if (typeof server.command !== "string") return undefined
  const args = Array.isArray(server.args) ? server.args.map((a) => expand(String(a))) : []
  return compact({
    type: "local",
    command: [expand(server.command), ...args],
    environment: expandRecord(server.env),
    // Codex resolves a relative cwd against the plugin root; opencode would use the
    // workspace, so make it absolute here.
    cwd: typeof server.cwd === "string" ? path.resolve(ROOT, expand(server.cwd)) : undefined,
  })
}

function readMcpServers() {
  const file = path.join(ROOT, ".mcp.json")
  if (!fs.existsSync(file)) return {}
  const json = JSON.parse(fs.readFileSync(file, "utf8"))
  return json.mcpServers ?? {}
}

// --- plugin --------------------------------------------------------------------

async function server() {
  return {
    // opencode calls this once per project instance, before skills, commands,
    // agents, and MCP servers are resolved, so mutations here take effect.
    config: async (config) => {
      const skillsDir = path.join(ROOT, "skills")
      if (fs.existsSync(skillsDir)) {
        config.skills = config.skills ?? {}
        const paths = (config.skills.paths = config.skills.paths ?? [])
        if (!paths.includes(skillsDir)) paths.push(skillsDir)
      }

      config.command = config.command ?? {}
      for (const file of markdownFiles("commands")) {
        const { data, body } = parseMarkdown(file)
        const name = componentName(file, data)
        if (!(name in config.command)) config.command[name] = pickCommand(data, body)
      }

      config.agent = config.agent ?? {}
      for (const file of markdownFiles("agents")) {
        const { data, body } = parseMarkdown(file)
        const name = componentName(file, data)
        if (!(name in config.agent)) config.agent[name] = pickAgent(data, body)
      }

      config.mcp = config.mcp ?? {}
      for (const [name, server] of Object.entries(readMcpServers())) {
        const mapped = toOpencodeMcp(server)
        if (mapped && !(name in config.mcp)) config.mcp[name] = mapped
      }
    },
  }
}

export default { id: PKG.name, server }

#!/usr/bin/env node
// MCP server for the Services widget. Speaks Model Context Protocol over
// stdio, so the agent client spawns it as a local subprocess: no listener,
// no daemon, no telemetry.
//
// Every tool is backed by the same pieces the panel uses:
//   lib/Model.js     validation and state (the same model the QML calls)
//   lib/collect.sh   local discovery, network scan, TCP/UDP probes
//   services.conf    the same pin list the bar widget hot-reloads
//
// Actions are validated argv arrays (systemctl, docker, ssh -- script verb);
// nothing is ever interpolated into a shell string. An agent cannot do
// anything the panel cannot.

"use strict"

const fs = require("fs")
const os = require("os")
const path = require("path")
const { execFile } = require("child_process")
const Model = require("../lib/Model.js")

const PROTOCOL_VERSION = "2025-06-18"
const COLLECT = path.join(__dirname, "..", "lib", "collect.sh")

const configPath = () =>
  process.env.OMARCHY_SERVICES_CONFIG ||
  (process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config")) + "/omarchy/services.conf"

// The single switch lives in the widget panel: this marker file exists while
// agent access is enabled. Re-checked on every mutating call, so toggling the
// widget takes effect in already-running agent sessions.
const gatePath = () =>
  process.env.OMARCHY_SERVICES_MCP_GATE ||
  path.join(path.dirname(configPath()), "services-mcp-on")

function mcpEnabled() {
  try {
    fs.accessSync(gatePath())
    return true
  } catch (e) {
    return false
  }
}

const MUTATING_TOOLS = new Set(["services_action", "services_pin", "services_unpin"])

function exec(args, timeoutMs) {
  return new Promise((resolve) => {
    execFile(args[0], args.slice(1), { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 },
      (error, stdout, stderr) => {
        resolve({
          code: error ? (typeof error.code === "number" ? error.code : 1) : 0,
          stdout: String(stdout || ""),
          stderr: String(stderr || "").trim(),
          killed: Boolean(error && error.killed)
        })
      })
  })
}

function runCollect(subcommand, extraArgs) {
  return exec(["/usr/bin/env", "bash", COLLECT, subcommand].concat(extraArgs || []), 90000)
}

function localHostname() {
  try { return fs.readFileSync("/proc/sys/kernel/hostname", "utf8").trim() } catch (e) { return os.hostname() }
}

function isLocalTarget(host) {
  const value = String(host || "")
  return value === "localhost" || value === "127.0.0.1" || value === "::1" || value === localHostname()
}

// Same rules as Service.qml: a remote entry names a script on the target, so
// the widget or an agent can only ever ask that script to start/stop/restart.
function remoteCommand(entry, verb) {
  const host = String(entry.host || "")
  const script = String(entry.script || "")
  const user = String(entry.user || "")
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(host)) return null
  if (!/^\/[A-Za-z0-9._~%+/-]*$/.test(script) || script.length > 200) return null
  if (user !== "" && !/^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/.test(user)) return null
  if (isLocalTarget(host)) return [script, verb]
  const command = ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
    "-o", "StrictHostKeyChecking=accept-new"]
  command.push(user !== "" ? user + "@" + host : host)
  command.push("--", script, verb)
  return command
}

function actionCommand(entry, verb) {
  if (entry.type === "unit") {
    const command = entry.scope === "user"
      ? ["/usr/bin/systemctl", "--user", verb, entry.unit]
      : ["/usr/bin/systemctl", verb, entry.unit]
    if (verb === "stop" && Array.isArray(entry.stopUnits)) command.push(...entry.stopUnits.slice(0, 8))
    return command
  }
  if (entry.type === "container") return ["/usr/bin/docker", verb, entry.name]
  if (entry.type === "remote") return remoteCommand(entry, verb)
  return null
}

// --- state ----------------------------------------------------------------

async function loadContext() {
  const config = Model.parseConfigText(readConfigText())
  const local = await runCollect("local")
  let data = {}
  try { data = JSON.parse(local.stdout || "{}") } catch (e) {}
  const context = {
    systemUnits: Model.parseUnitsJson(JSON.stringify(data.systemUnits || []), "system"),
    userUnits: Model.parseUnitsJson(JSON.stringify(data.userUnits || []), "user"),
    docker: data.docker && typeof data.docker === "object"
      ? data.docker : { available: false, reason: "", containers: [] },
    probes: {}
  }
  const pairs = Model.probePairs(config.entries)
  if (pairs !== "") {
    const tokens = pairs.split(/\s+/).filter((token) => token !== "")
    const probe = await runCollect("probe-many", tokens)
    try { context.probes = JSON.parse(probe.stdout || "{}") } catch (e) {}
  }
  return { config, context }
}

function readConfigText() {
  try { return fs.readFileSync(configPath(), "utf8") } catch (e) { return Model.HEADER }
}

// Writes the pin file atomically with the same permissions the widget keeps.
function writeConfigText(text) {
  const target = configPath()
  fs.mkdirSync(path.dirname(target), { recursive: true })
  const tmp = target + ".tmp." + process.pid
  fs.writeFileSync(tmp, text, { mode: 0o600 })
  fs.chmodSync(tmp, 0o600)
  fs.renameSync(tmp, target)
  fs.chmodSync(target, 0o600)
}

function findEntry(config, id) {
  for (const entry of config.entries) if (entry.id === id) return entry
  return null
}

// --- tools ----------------------------------------------------------------

const toolList = [
  {
    name: "services_status",
    description: "List the services pinned in the Services widget with their live state. Also returns the pinned entry definitions so a caller can act on them by id.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    readOnlyHint: true
  },
  {
    name: "services_machine",
    description: "Services running on this machine: systemd units (system and user), unattributed TCP listeners, and Docker containers when the socket is readable.",
    inputSchema: {
      type: "object",
      properties: { showAll: { type: "boolean", description: "Include inactive units, not just active ones." } },
      additionalProperties: false
    },
    readOnlyHint: true
  },
  {
    name: "services_network",
    description: "Scan the local network: ARP neighbours, whitelisted mDNS service types, and online Tailscale peers, with a short fixed port list and UDP 19132 (Minecraft Bedrock) checked on each. Only private addresses are probed. Takes a few seconds.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    readOnlyHint: true
  },
  {
    name: "services_action",
    description: "Start, stop, or restart a pinned service by id: a systemd unit, a Docker container, or a remote entry (a named control script on another machine). Returns the command output. Use services_status or services_machine to find ids and check state first.",
    destructiveHint: true,
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Entry id, e.g. unit:system:docker.service or remote:host:script" },
        verb: { type: "string", enum: ["start", "stop", "restart"] }
      },
      required: ["id", "verb"],
      additionalProperties: false
    }
  },
  {
    name: "services_pin",
    description: "Pin a service so the bar widget and future calls can act on it. Accepted types: unit (scope system|user, unit name), container (Docker name), probe (host, port, optional scheme http|https, path), remote (host, user, script path, optional probePort, probeProto udp|tcp).",
    inputSchema: {
      type: "object",
      properties: {
        type: { type: "string", enum: ["unit", "container", "probe", "remote"] },
        scope: { type: "string", enum: ["system", "user"] },
        unit: { type: "string" },
        name: { type: "string" },
        stopUnits: { type: "array", items: { type: "string" } },
        host: { type: "string" },
        port: { type: "integer" },
        proto: { type: "string", enum: ["tcp", "udp"] },
        scheme: { type: "string", enum: ["http", "https"] },
        path: { type: "string" },
        user: { type: "string" },
        script: { type: "string" },
        probePort: { type: "integer" },
        probeProto: { type: "string", enum: ["tcp", "udp"] }
      },
      required: ["type"],
      additionalProperties: false
    }
  },
  {
    name: "services_unpin",
    description: "Unpin a service by id. The config line is commented out, not deleted, so re-pinning restores it.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string" } },
      required: ["id"],
      additionalProperties: false
    }
  }
]

async function callTool(name, args) {
  if (MUTATING_TOOLS.has(name) && !mcpEnabled())
    throw new Error("Agent access is switched off. Enable it in the Services widget panel, then retry.")
  if (name === "services_status") {
    const { config, context } = await loadContext()
    const rows = Model.pinnedRows(config.entries.filter((entry) => entry.pinned), context)
    return {
      summary: Model.summary(config.entries.filter((entry) => entry.pinned), context),
      configErrors: config.errors,
      agentAccess: { enabled: mcpEnabled() },
      rows: rows,
      entries: config.entries.filter((entry) => entry.pinned)
    }
  }
  if (name === "services_machine") {
    const { config, context } = await loadContext()
    const rows = Model.machineRows(
      context.systemUnits, context.userUnits, [], config.entries,
      Boolean(args && args.showAll), context.docker.containers
    )
    return {
      docker: context.docker,
      rows: rows
    }
  }
  if (name === "services_network") {
    const scan = await runCollect("network")
    let data = {}
    try { data = JSON.parse(scan.stdout || "{}") } catch (e) {}
    if (scan.code !== 0 && !scan.stdout) throw new Error(scan.stderr || "network scan failed")
    const config = Model.parseConfigText(readConfigText())
    return {
      scannedAt: data.scannedAt || 0,
      warnings: data.warnings || [],
      hosts: data.hosts || [],
      rows: Model.networkRows({ hosts: data.hosts || [] }, config.entries)
    }
  }
  if (name === "services_action") {
    const id = String((args && args.id) || "")
    const verb = String((args && args.verb) || "")
    if (verb !== "start" && verb !== "stop" && verb !== "restart") throw new Error("verb must be start, stop, or restart")
    const { config, context } = await loadContext()
    const entry = findEntry(config, id)
    if (!entry) throw new Error("no entry with id " + id)
    if (!entry.pinned) throw new Error("entry " + id + " is not pinned; pin it first with services_pin")
    const command = actionCommand(entry, verb)
    if (!command) throw new Error("entry type does not support actions")
    if (entry.type === "container" && !context.docker.available)
      throw new Error("Docker socket is not accessible to this user: " + (context.docker.reason || "unknown"))
    const result = await exec(command, verb === "stop" ? 30000 : 60000)
    if (result.code !== 0 && !result.stdout && !result.stderr)
      throw new Error("action failed (exit " + result.code + "): " + command.join(" "))
    return {
      verb: verb,
      id: id,
      command: command,
      exitCode: result.code,
      output: (result.stdout + (result.stderr ? "\n" + result.stderr : "")).trim()
    }
  }
  if (name === "services_pin") {
    const problem = Model.validateEntry(args)
    if (problem !== "") throw new Error("invalid entry: " + problem)
    const text = Model.pinText(readConfigText(), args)
    writeConfigText(text)
    const parsed = Model.parseConfigText(text)
    const entry = findEntry(parsed, Model.entryId(args))
    return { pinned: true, entry: entry, errors: parsed.errors }
  }
  if (name === "services_unpin") {
    const id = String((args && args.id) || "")
    writeConfigText(Model.unpinText(readConfigText(), id))
    return { unpinned: id }
  }
  throw new Error("unknown tool: " + name)
}

// --- MCP plumbing ----------------------------------------------------------

function textResult(payload, isError) {
  const body = typeof payload === "string" ? payload : JSON.stringify(payload, null, 2)
  return { content: [{ type: "text", text: body }], isError: Boolean(isError) }
}

function respond(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: id, result: result }) + "\n")
}

function respondError(id, code, message) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: id, error: { code: code, message: message } }) + "\n")
}

async function handleMessage(message) {
  if (!message || message.jsonrpc !== "2.0") return
  const method = String(message.method || "")
  if (method === "initialize") {
    const requested = String((message.params && message.params.protocolVersion) || "")
    respond(message.id, {
      protocolVersion: requested || PROTOCOL_VERSION,
      capabilities: { tools: {} },
      serverInfo: { name: "io.github.nam.services", title: "Services", version: "0.5.0" }
    })
    return
  }
  if (method === "notifications/initialized" || method.startsWith("notifications/")) return
  if (method === "ping") { respond(message.id, {}); return }
  if (method === "tools/list") {
    respond(message.id, { tools: toolList })
    return
  }
  if (method === "tools/call") {
    const name = String((message.params && message.params.name) || "")
    const args = (message.params && message.params.arguments) || {}
    try {
      const payload = await callTool(name, args)
      respond(message.id, payload)
    } catch (error) {
      respond(message.id, textResult(String(error && error.message || error), true))
    }
    return
  }
  if (message.id !== undefined) respondError(message.id, -32601, "method not found: " + method)
}

let buffer = ""
process.stdin.setEncoding("utf8")
process.stdin.on("data", (chunk) => {
  buffer += chunk
  let index
  while ((index = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, index)
    buffer = buffer.slice(index + 1)
    if (line.trim() === "") continue
    let message
    try { message = JSON.parse(line) } catch (e) { continue }
    handleMessage(message)
  }
})
process.stdin.on("end", () => process.exit(0))
process.on("SIGTERM", () => process.exit(0))
process.on("SIGINT", () => process.exit(0))

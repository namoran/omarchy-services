// Pure logic for the Services widget. No Qt imports: this file is also run
// under `node --test` so the config round-trip, discovery filters, and entry
// validation are covered without a running shell.

var HEADER = [
  "# Omarchy Services — one service per line.",
  "# Pinned = active line. Unpinned = line starting with // (kept so re-pinning is one click).",
  "# This file is machine-local and can contain private hostnames. Do not commit it.",
  ""
].join("\n")

var UNIT_RE = /^[A-Za-z0-9][A-Za-z0-9:_.@-]*\.(service|socket|timer|scope)$/
var CONTAINER_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/
var HOST_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/
var PATH_RE = /^\/[A-Za-z0-9._~%+/-]*$/
var USER_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/
var TYPES = { unit: true, container: true, probe: true, remote: true }

var PORT_LABELS = {
  21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS",
  80: "HTTP", 111: "RPCbind", 139: "NetBIOS", 443: "HTTPS",
  445: "SMB", 631: "Printing", 1883: "MQTT", 2049: "NFS",
  3000: "Dev server", 3306: "MySQL", 3389: "RDP", 5000: "Dev server",
  5001: "Dev server", 5432: "PostgreSQL", 5601: "Kibana", 5900: "VNC",
  6379: "Redis", 8000: "Dev server", 8006: "Proxmox", 8080: "HTTP alt",
  8081: "HTTP alt", 8096: "Jellyfin", 8123: "Home Assistant",
  8384: "Syncthing", 8443: "HTTPS alt", 8888: "HTTP alt", 9000: "HTTP alt",
  9090: "Cockpit", 9100: "node_exporter", 9200: "Elasticsearch",
  11434: "Ollama", 19132: "Minecraft Bedrock", 19999: "Netdata",
  25565: "Minecraft Java", 27017: "MongoDB", 32400: "Plex"
}

// Ports that answer with a browser-friendly page, and the scheme to try.
// Anything else gets no open action rather than a misleading one.
var WEB_SCHEMES = {
  80: "http", 443: "https", 3000: "http", 5000: "http", 5001: "https",
  631: "http", 8000: "http", 8006: "https", 8080: "http", 8081: "http",
  8096: "http", 8123: "http", 8443: "https", 8888: "http", 9000: "http",
  9090: "https", 11434: "http", 19999: "http", 32400: "http"
}

// Systemd units every Omarchy box has and nobody wants in a services widget.
var INFRA_PREFIXES = [
  "dbus-", "dbus.", "gvfs-", "systemd-", "user@", "user-runtime-dir",
  "session-", "getty@", "serial-getty@", "at-spi", "xdg-", "colord",
  "rtkit", "polkit", "udisks", "upower", "accounts-daemon",
  "switcheroo", "ModemManager", "avahi-daemon", "NetworkManager",
  "wpa_supplicant", "cups-browsed", "thermald", "bolt",
  "power-profiles-daemon", "bluetooth", "bt-agent", "dconf",
  "gnome-keyring", "alsa-", "kmod-", "ldconfig", "plymouth",
  "sddm", "limine-", "t2fanrd", "containerd", "ufw",
  "pipewire", "wireplumber", "wayland-session-", "wayland-wm-",
  "wayland-wm@", "omarchy-crash-watch", "omarchy-sleep-lock",
  "omarchy-browser-"
]

function cleanLabel(value, maxLength) {
  var limit = typeof maxLength === "number" ? maxLength : 72
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
  text = text.replace(/\s+/g, " ").trim()
  if (text.length > limit) text = text.slice(0, Math.max(0, limit - 1)) + "…"
  return text
}

function normalizeText(text) {
  return String(text === undefined || text === null ? "" : text)
    .replace(/\r\n/g, "\n").replace(/\r/g, "\n")
}

function isCommented(line) {
  return /^\s*\/\//.test(line)
}

function uncommentLine(line) {
  return line.replace(/^(\s*)\/\/[ ]?/, "$1")
}

function entryId(entry) {
  if (!entry || typeof entry !== "object") return ""
  if (entry.type === "unit") return "unit:" + String(entry.scope || "") + ":" + String(entry.unit || "")
  if (entry.type === "container") return "container:" + String(entry.name || "")
  if (entry.type === "probe") return "probe:" + String(entry.host || "") + ":" + String(entry.port || "") + (entry.proto === "udp" ? ":udp" : "")
  if (entry.type === "remote")
    return "remote:" + String(entry.host || "") + ":" + scriptName(entry.script)
  return ""
}

// Script paths are absolute and validated by PATH_RE, so this never has to
// handle odd input; it exists so ids stay readable against the remote target.
function scriptName(path) {
  return String(path || "").replace(/\/+$/, "").replace(/^.*\//, "")
}

function validateEntry(entry) {
  if (!entry || typeof entry !== "object") return "entry is not an object"
  if (!TYPES[String(entry.type || "")]) return "unknown type"
  if (entry.type === "unit") {
    if (entry.scope !== "user" && entry.scope !== "system") return "unit scope must be user or system"
    if (!UNIT_RE.test(String(entry.unit || ""))) return "invalid unit name"
    if (entry.stopUnits !== undefined) {
      if (Object.prototype.toString.call(entry.stopUnits) !== "[object Array]") return "stopUnits must be an array"
      for (var i = 0; i < entry.stopUnits.length; i++)
        if (!UNIT_RE.test(String(entry.stopUnits[i] || ""))) return "invalid stopUnits entry"
      if (entry.stopUnits.length > 8) return "too many stopUnits entries"
    }
    return ""
  }
  if (entry.type === "container") {
    if (!CONTAINER_RE.test(String(entry.name || ""))) return "invalid container name"
    return ""
  }
  if (entry.type === "remote") {
    // host/user/script are re-checked at execution time too; this is the
    // config-layer gate. A script is a path to a file the user controls on
    // the target, never a command line.
    if (!HOST_RE.test(String(entry.host || ""))) return "invalid host"
    if (String(entry.host).length > 253) return "host too long"
    if (entry.user !== undefined) {
      if (typeof entry.user !== "string" || !USER_RE.test(entry.user)) return "invalid user"
    }
    if (typeof entry.script !== "string" || entry.script.length > 200 || !PATH_RE.test(entry.script))
      return "invalid script"
    var remoteProto = entry.probeProto === undefined ? "tcp" : String(entry.probeProto)
    if (remoteProto !== "tcp" && remoteProto !== "udp") return "invalid probeProto"
    if (entry.probePort !== undefined) {
      var remotePort = Number(entry.probePort)
      if (!isFinite(remotePort) || remotePort < 1 || remotePort > 65535 || Math.floor(remotePort) !== remotePort)
        return "invalid probePort"
    }
    return ""
  }
  if (!HOST_RE.test(String(entry.host || ""))) return "invalid host"
  if (String(entry.host).length > 253) return "host too long"
  var port = Number(entry.port)
  if (!isFinite(port) || port < 1 || port > 65535 || Math.floor(port) !== port) return "invalid port"
  if (entry.proto !== undefined && entry.proto !== "tcp" && entry.proto !== "udp") return "invalid proto"
  if (entry.scheme !== undefined && entry.scheme !== "http" && entry.scheme !== "https") return "invalid scheme"
  if (entry.path !== undefined) {
    if (typeof entry.path !== "string" || entry.path.length > 200 || !PATH_RE.test(entry.path))
      return "invalid path"
  }
  return ""
}

function canonicalEntry(entry) {
  var out = {}
  if (entry.type === "unit") {
    out.id = entryId(entry)
    out.type = "unit"
    out.scope = entry.scope
    out.unit = entry.unit
    if (entry.name) out.name = cleanLabel(entry.name, 72)
    if (entry.stopUnits && entry.stopUnits.length) out.stopUnits = entry.stopUnits.slice(0, 8)
  } else if (entry.type === "container") {
    out.id = entryId(entry)
    out.type = "container"
    out.name = entry.name
    if (entry.label) out.label = cleanLabel(entry.label, 72)
  } else if (entry.type === "probe") {
    out.id = entryId(entry)
    out.type = "probe"
    out.host = entry.host
    out.port = Number(entry.port)
    if (entry.proto) out.proto = entry.proto
    if (entry.scheme) out.scheme = entry.scheme
    if (entry.path) out.path = entry.path
    if (entry.name) out.name = cleanLabel(entry.name, 72)
  } else if (entry.type === "remote") {
    out.id = entryId(entry)
    out.type = "remote"
    out.host = entry.host
    out.script = entry.script
    if (entry.user) out.user = entry.user
    if (entry.probePort !== undefined) out.probePort = Number(entry.probePort)
    if (entry.probeProto) out.probeProto = entry.probeProto
    if (entry.name) out.name = cleanLabel(entry.name, 72)
  }
  return out
}

function serializeEntry(entry) {
  return JSON.stringify(canonicalEntry(entry))
}

function ensureHeader(text) {
  var normalized = normalizeText(text)
  if (normalized.trim() === "") return HEADER
  if (/^#/.test(normalized)) return normalized
  return HEADER + normalized
}

// Parses the JSONL-with-comments config. Bad lines are reported, never guessed
// at, and never cause the rest of the file to be discarded.
function parseConfigText(text) {
  var lines = normalizeText(text).split("\n")
  var entries = []
  var errors = []
  var seen = {}
  for (var i = 0; i < lines.length; i++) {
    var raw = lines[i]
    var trimmed = raw.trim()
    if (trimmed === "" || trimmed.charAt(0) === "#") continue
    var pinned = !isCommented(raw)
    var body = pinned ? trimmed : uncommentLine(raw).trim()
    if (body === "") continue
    var parsed
    try {
      parsed = JSON.parse(body)
    } catch (e) {
      errors.push({ line: i + 1, message: "not valid JSON" })
      continue
    }
    var problem = validateEntry(parsed)
    if (problem !== "") {
      errors.push({ line: i + 1, message: problem })
      continue
    }
    var id = entryId(parsed)
    if (seen[id]) {
      errors.push({ line: i + 1, message: "duplicate id" })
      continue
    }
    seen[id] = true
    var entry = canonicalEntry(parsed)
    entry.pinned = pinned
    entries.push(entry)
  }
  return { entries: entries, errors: errors }
}

function pinText(text, entry) {
  var problem = validateEntry(entry)
  if (problem !== "") return ensureHeader(text)
  var base = ensureHeader(text)
  var lines = base.split("\n")
  var id = entryId(entry)
  var found = false
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() === "" || lines[i].trim().charAt(0) === "#") continue
    var parsed
    try {
      parsed = JSON.parse(uncommentLine(lines[i]).trim())
    } catch (e) {
      continue
    }
    if (entryId(parsed) !== id) continue
    found = true
    if (!isCommented(lines[i])) return base
    lines[i] = uncommentLine(lines[i])
  }
  if (found) return lines.join("\n")
  if (lines.length && lines[lines.length - 1] === "") lines[lines.length - 1] = serializeEntry(entry)
  else lines.push(serializeEntry(entry))
  if (lines[lines.length - 1] !== "") lines.push("")
  return lines.join("\n")
}

function unpinText(text, id) {
  var base = ensureHeader(text)
  var lines = base.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var trimmed = lines[i].trim()
    if (trimmed === "" || trimmed.charAt(0) === "#" || isCommented(lines[i])) continue
    var parsed
    try {
      parsed = JSON.parse(trimmed)
    } catch (e) {
      continue
    }
    if (entryId(parsed) !== id) continue
    lines[i] = lines[i].replace(/^(\s*)/, "$1// ")
  }
  return lines.join("\n")
}

function findEntry(entries, id) {
  for (var i = 0; i < (entries || []).length; i++)
    if (entries[i].id === id) return entries[i]
  return null
}

function isPinned(entries, id) {
  var entry = findEntry(entries, id)
  return !!(entry && entry.pinned)
}

function parseUnitsJson(raw, scope) {
  var data
  try {
    data = JSON.parse(String(raw || "[]"))
  } catch (e) {
    return []
  }
  if (Object.prototype.toString.call(data) !== "[object Array]") return []
  var out = []
  for (var i = 0; i < data.length; i++) {
    var item = data[i] || {}
    var name = String(item.unit || "")
    if (!UNIT_RE.test(name)) continue
    out.push({
      name: name,
      label: cleanLabel(item.description || name, 72),
      active: String(item.active || "") === "active",
      sub: String(item.sub || ""),
      load: String(item.load || ""),
      scope: scope
    })
  }
  return out
}

function isInfraUnit(name) {
  var value = String(name || "")
  for (var i = 0; i < INFRA_PREFIXES.length; i++)
    if (value.indexOf(INFRA_PREFIXES[i]) === 0) return true
  return false
}

function shortUnitName(name) {
  return String(name || "").replace(/\.(service|socket|timer|scope)$/, "")
}

function unitRow(unit, entries) {
  var id = "unit:" + unit.scope + ":" + unit.name
  return {
    kind: "unit",
    id: id,
    title: shortUnitName(unit.name),
    subtitle: unit.label,
    scope: unit.scope,
    active: unit.active,
    available: unit.load !== "not-found",
    pinned: isPinned(entries, id),
    entry: {
      type: "unit",
      scope: unit.scope,
      unit: unit.name,
      name: shortUnitName(unit.name)
    }
  }
}

function machineRows(systemUnits, userUnits, listeners, entries, showAll, containers) {
  var rows = []
  var scopes = [
    { list: systemUnits || [], scope: "system" },
    { list: userUnits || [], scope: "user" }
  ]
  for (var s = 0; s < scopes.length; s++) {
    var list = scopes[s].list
    for (var i = 0; i < list.length; i++) {
      var unit = list[i]
      if (!showAll && !unit.active) continue
      if (isInfraUnit(unit.name)) continue
      rows.push(unitRow(unit, entries))
    }
  }
  var attributed = {}
  for (var r = 0; r < rows.length; r++) attributed[rows[r].title] = true
  for (var c = 0; c < (containers || []).length; c++) {
    var container = containers[c]
    if (!container || !container.name) continue
    var containerId = "container:" + container.name
    rows.push({
      kind: "container",
      id: containerId,
      title: container.name,
      subtitle: "container · " + (container.image || container.status || ""),
      scope: "docker",
      active: container.state === "running",
      available: true,
      pinned: isPinned(entries, containerId),
      entry: { type: "container", name: container.name, label: container.name }
    })
  }
  var seenPorts = {}
  for (var l = 0; l < (listeners || []).length; l++) {
    var item = listeners[l]
    if (item.unit && attributed[shortUnitName(item.unit)]) continue
    if (item.unit) {
      var unitHost = (item.addr === "0.0.0.0" || item.addr === "::" || !item.addr) ? "127.0.0.1" : item.addr
      rows.push({
        kind: "unit",
        id: "unit:" + item.scope + ":" + item.unit,
        title: shortUnitName(item.unit),
        subtitle: item.process ? item.process + " · port " + item.port : "port " + item.port,
        scope: item.scope,
        active: true,
        available: true,
        pinned: isPinned(entries, "unit:" + item.scope + ":" + item.unit),
        action: probeAction({ type: "probe", host: unitHost, port: Number(item.port) }),
        entry: { type: "unit", scope: item.scope, unit: item.unit, name: shortUnitName(item.unit) }
      })
      attributed[shortUnitName(item.unit)] = true
      continue
    }
    // Unattributed root listeners (systemd-resolved, cupsd) appear once per
    // bound address, so collapse them by port and name them by their port.
    if (seenPorts[item.port]) continue
    seenPorts[item.port] = true
    var probeId = "probe:127.0.0.1:" + item.port
    var probeLabel = item.process || portLabel(item.port)
    var probeEntry = { type: "probe", host: "127.0.0.1", port: Number(item.port), name: probeLabel }
    rows.push({
      kind: "probe",
      id: probeId,
      title: probeLabel,
      subtitle: (item.addr === "127.0.0.1" || item.addr === "::1" ? "this computer" : item.addr) + " · port " + item.port,
      scope: "local",
      active: true,
      available: true,
      pinned: isPinned(entries, probeId),
      action: probeAction(probeEntry),
      entry: probeEntry
    })
  }
  rows.sort(function(a, b) {
    if (a.active !== b.active) return a.active ? -1 : 1
    return a.title.toLowerCase() < b.title.toLowerCase() ? -1 : 1
  })
  return rows
}

function portLabel(port) {
  return PORT_LABELS[Number(port)] || ("Port " + port)
}

// macOS AirPlay Receiver answers HTTP on 5000 with an AirTunes server header.
// It has no page, so label it and keep it out of the pin list.
function isAirPlayServer(server) {
  return /airtunes|airplay/i.test(String(server === undefined || server === null ? "" : server))
}

function probeProtocol(port) {
  var p = Number(port)
  if (p === 22) return "ssh"
  if (WEB_SCHEMES[p]) return "web"
  return ""
}

function probeUrl(entry) {
  var port = Number(entry.port)
  var scheme = WEB_SCHEMES[port] || "http"
  if (entry.scheme === "http" || entry.scheme === "https") scheme = entry.scheme
  var host = String(entry.host || "")
  if (host.indexOf(":") !== -1 && host.charAt(0) !== "[") host = "[" + host + "]"
  var defaultPort = (scheme === "http" && port === 80) || (scheme === "https" && port === 443)
  var path = entry.path || "/"
  return scheme + "://" + host + (defaultPort ? "" : ":" + port) + path
}

// Returns a small, UI-agnostic action description. Only probe entries have
// one: units and containers get start/stop/restart instead.
function probeAction(entry) {
  if (!entry || entry.type !== "probe") return null
  var host = String(entry.host || "")
  if (host.length > 253 || !HOST_RE.test(host)) return null
  var port = Number(entry.port)
  if (!isFinite(port) || port < 1 || port > 65535) return null
  var protocol = probeProtocol(port)
  if (protocol === "ssh") return { kind: "ssh", label: "ssh", host: host, port: port }
  if (protocol === "web") return { kind: "open", label: "open", url: probeUrl(entry) }
  return null
}

function networkRows(network, entries) {
  var hosts = (network && network.hosts) || []
  var out = []
  for (var i = 0; i < hosts.length; i++) {
    var host = hosts[i]
    var services = host.services || []
    // One Synology endpoint identifies the whole host: 5000 redirects to
    // 5001 without naming itself, while 80/5001 answer with Synology pages.
    var hostSynology = false
    for (var h = 0; h < services.length; h++)
      if (services[h].synology === true) hostSynology = true
    for (var s = 0; s < services.length; s++) {
      var svc = services[s]
      var hostName = String(host.name || host.ip || "")
      var port = Number(svc.port)
      var proto = svc.proto === "udp" ? "udp" : "tcp"
      var id = "probe:" + hostName + ":" + svc.port + (proto === "udp" ? ":udp" : "")
      var server = cleanLabel(svc.server || "", 48)
      var pageTitle = cleanLabel(svc.title || "", 64)
      var airplay = isAirPlayServer(server)
      var synology = svc.synology === true ||
        (hostSynology && (port === 80 || port === 443 || port === 5000 || port === 5001))
      var title
      var subtitle = hostName + " · port " + svc.port
      if (airplay) {
        title = "AirPlay Receiver"
        subtitle += " · no web UI"
      } else if (synology) {
        if (port === 5000) {
          title = "Synology DSM"
          subtitle += " · redirects to :5001"
        } else if (/web station/i.test(pageTitle)) {
          title = "Synology Web Station"
          subtitle += " · placeholder page"
        } else if (pageTitle !== "" && !/^(synology|diskstation)/i.test(pageTitle)) {
          title = pageTitle
          subtitle += " · DSM web UI"
        } else {
          title = "Synology DSM"
          subtitle += " · DSM web UI"
        }
      } else if (port === 19132 && (proto === "udp" || svc.players !== undefined)) {
        // Bedrock, either era. Older servers speak RakNet over UDP and answer
        // the ping with their MOTD; BDS 26.50+ runs NetherNet and exposes a
        // JSON join endpoint on TCP 19132 instead.
        title = pageTitle !== "" ? pageTitle : portLabel(port)
        subtitle += proto === "udp"
          ? " · UDP"
          : " · NetherNet"
        if (svc.maxPlayers !== undefined)
          subtitle += " · " + (svc.players || 0) + "/" + svc.maxPlayers + " players"
      } else {
        title = cleanLabel(svc.name || portLabel(svc.port), 64)
        if (svc.source === "mdns") subtitle += " · mDNS"
        else if (server !== "") subtitle += " · " + server
      }
      var entry = {
        type: "probe",
        host: hostName,
        port: port,
        name: title,
        proto: proto === "udp" ? "udp" : undefined,
        scheme: port === 443 || port === 8443 || port === 5001 ? "https" : undefined
      }
      out.push({
        kind: "network",
        host: hostName,
        ip: host.ip || "",
        sources: host.sources || [],
        id: id,
        title: title,
        subtitle: subtitle,
        server: server,
        proto: proto,
        players: svc.players,
        maxPlayers: svc.maxPlayers,
        pinnable: !airplay,
        port: port,
        pinned: isPinned(entries, id),
        action: airplay ? null : probeAction(entry),
        entry: entry
      })
    }
  }
  out.sort(function(a, b) {
    var left = (a.host + ":" + a.port).toLowerCase()
    var right = (b.host + ":" + b.port).toLowerCase()
    return left < right ? -1 : 1
  })
  return out
}

// Probe results are keyed by "host:port" for TCP; UDP gets its own namespace
// so a UDP server on one port is never confused with a TCP listener on it.
function probeResultKey(host, port, proto) {
  return proto === "udp" ? "udp:" + String(host) + ":" + String(port) : String(host) + ":" + String(port)
}

function entryState(entry, ctx) {
  var context = ctx || {}
  if (entry.type === "unit") {
    var list = entry.scope === "user" ? (context.userUnits || []) : (context.systemUnits || [])
    for (var i = 0; i < list.length; i++)
      if (list[i].name === entry.unit)
        return {
          state: list[i].active ? "active" : (list[i].sub === "failed" ? "failed" : "inactive"),
          label: list[i].active ? "running" : (list[i].sub === "failed" ? "failed" : "stopped")
        }
    return { state: "missing", label: "not installed" }
  }
  if (entry.type === "container") {
    var containers = (context.docker && context.docker.containers) || []
    for (var c = 0; c < containers.length; c++)
      if (containers[c].name === entry.name)
        return { state: containers[c].state === "running" ? "active" : "inactive", label: String(containers[c].state || "unknown") }
    return { state: "missing", label: "not found" }
  }
  if (entry.type === "probe") {
    var probeKey = probeResultKey(entry.host, entry.port, entry.proto)
    var probes = context.probes || {}
    if (probes[probeKey] === true) return { state: "active", label: "reachable" }
    if (probes[probeKey] === false) return { state: "inactive", label: "unreachable" }
    return { state: "unknown", label: "checking…" }
  }
  if (entry.type === "remote") {
    if (entry.probePort === undefined) return { state: "unknown", label: "no probe" }
    var remoteKey = probeResultKey(entry.host, entry.probePort, entry.probeProto)
    var remoteProbes = context.probes || {}
    if (remoteProbes[remoteKey] === true) return { state: "active", label: "reachable" }
    if (remoteProbes[remoteKey] === false) return { state: "inactive", label: "unreachable" }
    return { state: "unknown", label: "checking…" }
  }
  return { state: "unknown", label: "unknown" }
}

function pinnedRows(entries, ctx) {
  var out = []
  for (var i = 0; i < (entries || []).length; i++) {
    if (!entries[i].pinned) continue
    var entry = entries[i]
    var state = entryState(entry, ctx)
    var title, subtitle
    if (entry.type === "unit") {
      title = entry.name || shortUnitName(entry.unit)
      subtitle = (entry.scope === "user" ? "user" : "system") + " · " + entry.unit
    } else if (entry.type === "container") {
      title = entry.label || entry.name
      subtitle = "container · " + entry.name
    } else if (entry.type === "remote") {
      title = entry.name || scriptName(entry.script)
      subtitle = "remote · " + entry.host + (entry.user ? " · " + entry.user : "")
    } else {
      title = entry.name || portLabel(entry.port)
      subtitle = entry.host + " · " + portLabel(entry.port)
    }
    out.push({
      kind: entry.type,
      id: entry.id,
      title: cleanLabel(title, 64),
      subtitle: cleanLabel(subtitle, 80),
      state: state.state,
      stateLabel: state.label,
      active: state.state === "active",
      pinned: true,
      action: entry.type === "probe" ? probeAction(entry) : null,
      entry: entry
    })
  }
  return out
}

function probePairs(entries) {
  var lines = []
  for (var i = 0; i < (entries || []).length; i++) {
    var entry = entries[i]
    if (!entry.pinned) continue
    if (entry.type === "probe")
      lines.push(entry.host + " " + entry.port + " " + (entry.proto === "udp" ? "udp" : "tcp"))
    else if (entry.type === "remote" && entry.probePort !== undefined)
      lines.push(entry.host + " " + entry.probePort + " " + (entry.probeProto === "udp" ? "udp" : "tcp"))
  }
  return lines.join("\n")
}

function parseProbeJson(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    if (data && typeof data === "object") return data
  } catch (e) {}
  return {}
}

function summary(pinned, ctx) {
  var running = 0
  var issues = 0
  for (var i = 0; i < (pinned || []).length; i++) {
    var state = entryState(pinned[i], ctx).state
    if (state === "active") running++
    else if (state === "failed" || state === "inactive" || state === "missing") issues++
  }
  return { total: (pinned || []).length, running: running, issues: issues }
}

function configErrorsText(errors) {
  if (!errors || !errors.length) return ""
  var first = errors[0]
  return "services.conf line " + first.line + ": " + first.message
}

if (typeof module !== "undefined") {
  module.exports = {
    HEADER: HEADER,
    cleanLabel: cleanLabel,
    normalizeText: normalizeText,
    isCommented: isCommented,
    entryId: entryId,
    scriptName: scriptName,
    validateEntry: validateEntry,
    canonicalEntry: canonicalEntry,
    serializeEntry: serializeEntry,
    parseConfigText: parseConfigText,
    pinText: pinText,
    unpinText: unpinText,
    findEntry: findEntry,
    isPinned: isPinned,
    parseUnitsJson: parseUnitsJson,
    isInfraUnit: isInfraUnit,
    shortUnitName: shortUnitName,
    machineRows: machineRows,
    portLabel: portLabel,
    networkRows: networkRows,
    isAirPlayServer: isAirPlayServer,
    probeProtocol: probeProtocol,
    probeUrl: probeUrl,
    probeAction: probeAction,
    probeResultKey: probeResultKey,
    entryState: entryState,
    pinnedRows: pinnedRows,
    probePairs: probePairs,
    parseProbeJson: parseProbeJson,
    summary: summary,
    configErrorsText: configErrorsText
  }
}

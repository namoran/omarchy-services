import QtQuick
import Quickshell
import Quickshell.Io
import "lib/Model.js" as Model

// State for the Services widget.
//
// One poller, one config watcher, no daemon. All privileged or parsing work
// happens in lib/collect.sh with argv arrays; nothing discovered is ever
// interpolated into a shell string. Probe targets come from the user's own
// config, while discovery is capped and private-range-only inside the script.
Item {
  id: services
  visible: false

  property var settings: ({})

  readonly property string configPath: {
    var override = Quickshell.env("OMARCHY_SERVICES_CONFIG")
    if (override) return override
    var base = Quickshell.env("XDG_CONFIG_HOME")
    if (!base) base = (Quickshell.env("HOME") || "") + "/.config"
    return base + "/omarchy/services.conf"
  }
  readonly property string configDir: configPath.replace(/\/[^\/]*$/, "")
  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("lib/collect.sh"))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }
  readonly property int refreshSeconds: Math.max(5, Math.min(300, Number(settings && settings.refreshIntervalSec ? settings.refreshIntervalSec : 15)))

  property string configText: Model.HEADER
  property var entries: []
  property var configErrors: []
  property var systemUnits: []
  property var userUnits: []
  property var listeners: []
  property var docker: ({ available: false, reason: "", containers: [] })
  property var probes: ({})
  property var network: ({ hosts: [], warnings: [], scannedAt: 0 })
  property bool configReady: false
  property bool loading: false
  property bool scanning: false
  property bool acting: false
  property string lastError: ""
  property string actionMessage: ""
  property string actionError: ""
  property double lastProbeAt: 0
  property string localHostname: ""
  property bool mcpEnabled: false

  // MCP gate: the marker file is the single switch for agent access. The MCP
  // server re-checks it on every mutating call, so toggling here takes effect
  // in already-running agent sessions.
  readonly property string mcpGatePath: configDir + "/services-mcp-on"

  readonly property var pinnedEntries: {
    var out = []
    for (var i = 0; i < entries.length; i++)
      if (entries[i].pinned) out.push(entries[i])
    return out
  }
  readonly property var context: ({
    systemUnits: systemUnits,
    userUnits: userUnits,
    docker: docker,
    probes: probes
  })
  readonly property var summary: Model.summary(pinnedEntries, context)
  readonly property string configErrorText: Model.configErrorsText(configErrors)
  readonly property bool dockerAvailable: !!(docker && docker.available)

  function applyConfig(text) {
    var parsed = Model.parseConfigText(text)
    configText = text
    entries = parsed.entries
    configErrors = parsed.errors
    configReady = true
    maybeProbe()
  }

  function ensureConfig() {
    if (initProc.running) return
    initProc.running = true
  }

  function writeConfig(nextText) {
    configFile.setText(nextText)
    applyConfig(nextText)
    tightenPermissions()
  }

  // FileView writes asynchronously, so chmod has to trail it rather than race it.
  function tightenPermissions() {
    permissionsTimer.restart()
  }

  function pin(entry) {
    if (!entry) return
    writeConfig(Model.pinText(configFile.text(), entry))
  }

  function unpin(id) {
    writeConfig(Model.unpinText(configFile.text(), id))
  }

  function refresh() {
    if (collectProc.running) return
    loading = true
    collectProc.running = true
  }

  function maybeProbe() {
    var pairs = Model.probePairs(entries)
    if (pairs === "") return
    if (probeProc.running) return
    if (Date.now() - lastProbeAt < 5000) return
    lastProbeAt = Date.now()
    // Pairs are newline-joined "host port proto" triples; whitespace split
    // keeps them token-per-argument for collect.sh.
    var tokens = pairs.split(/\s+/).filter(function(token) { return token !== "" })
    probeProc.command = ["/usr/bin/env", "bash", helperPath, "probe-many"].concat(tokens)
    probeProc.running = true
  }

  function runAction(entry, verbOverride) {
    if (!entry || acting) return
    var state = Model.entryState(entry, context).state
    var verb = (state === "active") ? "stop" : (state === "failed" ? "restart" : "start")
    if (verbOverride === "start" || verbOverride === "stop" || verbOverride === "restart")
      verb = verbOverride
    var command = null
    if (entry.type === "unit") {
      command = entry.scope === "user" ? ["/usr/bin/systemctl", "--user", verb, entry.unit]
        : ["/usr/bin/systemctl", verb, entry.unit]
      if (verb === "stop" && entry.stopUnits && entry.stopUnits.length)
        command = command.concat(entry.stopUnits)
    } else if (entry.type === "container") {
      if (!dockerAvailable) {
        actionError = "Docker socket is not accessible to this user"
        return
      }
      command = ["/usr/bin/docker", verb, entry.name]
    } else if (entry.type === "remote") {
      command = remoteCommand(entry, verb)
      if (!command) {
        actionError = "remote entry has an invalid host or script"
        return
      }
      if (verb === "restart" && !localTarget(String(entry.host || "")))
        actionMessage = "restart " + (entry.name || "") + " (a few seconds over ssh)"
    } else {
      return
    }
    actionError = ""
    actionMessage = verb + " " + (entry.name || entry.unit || "")
    actionProc.command = command
    actionProc.running = true
  }

  // Remote entries name a script on the target machine, never a command
  // line. When the target is this machine the script runs directly;
  // otherwise over ssh with a fixed argv, so nothing discovered or written
  // into the config is ever interpolated into a shell string.
  function localTarget(host) {
    var value = String(host || "")
    return value === localHostname || value === "localhost" ||
      value === "127.0.0.1" || value === "::1"
  }

  function remoteCommand(entry, verb) {
    var host = String(entry.host || "")
    var script = String(entry.script || "")
    var user = String(entry.user || "")
    if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(host)) return null
    if (!/^\/[A-Za-z0-9._~%+/-]*$/.test(script) || script.length > 200) return null
    if (user !== "" && !/^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/.test(user)) return null
    if (localTarget(host)) return [script, verb]
    var command = ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
      "-o", "StrictHostKeyChecking=accept-new"]
    command.push(user !== "" ? user + "@" + host : host)
    command.push("--", script, verb)
    return command
  }

  // Open actions come from Model.probeAction. Re-check here too: these values
  // reach an argv array, never a shell, but a leading dash must not become an
  // ssh option.
  function runOpen(action) {
    if (!action) return
    if (action.kind === "open") {
      var url = String(action.url || "")
      if (!/^https?:\/\//.test(url)) return
      Quickshell.execDetached(["omarchy-launch-browser", url])
    } else if (action.kind === "ssh") {
      var host = String(action.host || "")
      var port = Number(action.port)
      if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(host)) return
      if (!isFinite(port) || port < 1 || port > 65535) return
      var command = ["omarchy-launch-terminal", "ssh"]
      if (port !== 22) command.push("-p", String(port))
      command.push(host)
      Quickshell.execDetached(command)
    }
  }

  function scanNetwork() {
    if (scanProc.running) {
      scanProc.running = false
      scanning = false
      return
    }
    lastError = ""
    scanning = true
    scanProc.running = true
  }

  function setMcpEnabled(on) {
    if (mcpToggleProc.running || mcpGateCheck.running) return
    mcpToggleProc.command = on ? ["/usr/bin/touch", mcpGatePath] : ["/usr/bin/rm", "-f", mcpGatePath]
    mcpToggleProc.running = true
  }

  function applyLocal(raw) {
    var data
    try {
      data = JSON.parse(raw)
    } catch (e) {
      lastError = "Discovery returned invalid data"
      return
    }
    systemUnits = Model.parseUnitsJson(JSON.stringify(data.systemUnits || []), "system")
    userUnits = Model.parseUnitsJson(JSON.stringify(data.userUnits || []), "user")
    listeners = Array.isArray(data.listeners) ? data.listeners : []
    docker = data.docker && typeof data.docker === "object"
      ? data.docker : ({ available: false, reason: "", containers: [] })
    lastError = ""
    maybeProbe()
  }

  function applyNetwork(raw) {
    var data
    try {
      data = JSON.parse(raw)
    } catch (e) {
      lastError = "Network scan returned invalid data"
      return
    }
    network = {
      hosts: Array.isArray(data.hosts) ? data.hosts : [],
      warnings: Array.isArray(data.warnings) ? data.warnings : [],
      scannedAt: Number(data.scannedAt || 0)
    }
    lastError = ""
  }

  FileView {
    id: configFile
    path: services.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: services.applyConfig(text())
    onFileChanged: reload()
    onLoadFailed: services.ensureConfig()
  }

  FileView {
    id: mcpGateFile
    path: services.mcpGatePath
    watchChanges: true
    printErrors: false
    onLoaded: services.mcpEnabled = true
    onLoadFailed: services.mcpEnabled = false
  }

  // The FileView notices the gate being created, but deletion is the flaky
  // direction. Every toggle therefore ends with an explicit existence test,
  // so the chip always reflects what is actually on disk.
  Process {
    id: mcpToggleProc
    onExited: mcpGateCheck.running = true
  }

  Process {
    id: mcpGateCheck
    command: ["/usr/bin/test", "-e", services.mcpGatePath]
    onExited: services.mcpEnabled = (mcpGateCheck.exitCode === 0)
  }

  Process {
    id: initProc
    command: ["/usr/bin/mkdir", "-p", services.configDir]
    onExited: {
      configFile.setText(Model.HEADER)
      services.applyConfig(Model.HEADER)
      services.tightenPermissions()
    }
  }

  Process {
    id: hostnameProc
    command: ["/usr/bin/cat", "/proc/sys/kernel/hostname"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: services.localHostname = text.trim()
    }
  }

  Component.onCompleted: {
    hostnameProc.running = true
  }

  Timer {
    id: permissionsTimer
    interval: 150
    onTriggered: chmodProc.running = true
  }

  Process {
    id: chmodProc
    command: ["/usr/bin/chmod", "600", services.configPath]
  }

  Process {
    id: collectProc
    command: ["/usr/bin/env", "bash", services.helperPath, "local"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: services.applyLocal(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text.trim() !== "") services.lastError = Model.cleanLabel(text, 160)
      }
    }
    onExited: services.loading = false
  }

  Process {
    id: probeProc
    command: ["/usr/bin/env", "bash", services.helperPath, "probe-many"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: services.probes = Model.parseProbeJson(text)
    }
    onExited: services.maybeProbe()
  }

  Process {
    id: scanProc
    command: ["/usr/bin/env", "bash", services.helperPath, "network"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: services.applyNetwork(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text.trim() !== "") services.lastError = Model.cleanLabel(text, 160)
      }
    }
    onExited: services.scanning = false
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text.trim() !== "") services.actionError = Model.cleanLabel(text, 160)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text.trim() !== "") services.actionError = Model.cleanLabel(text, 160)
      }
    }
    onExited: function(code) {
      services.acting = false
      services.actionMessage = ""
      if (code !== 0 && services.actionError === "")
        services.actionError = "action failed (exit " + code + ")"
      services.refresh()
    }
    onRunningChanged: services.acting = running
  }

  Timer {
    interval: services.refreshSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: services.refresh()
  }

  Timer {
    interval: 20000
    running: true
    repeat: true
    onTriggered: services.maybeProbe()
  }
}

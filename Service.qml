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
    probeProc.command = ["/usr/bin/env", "bash", helperPath, "probe-many"].concat(pairs.split(" "))
    probeProc.running = true
  }

  function runAction(entry) {
    if (!entry || acting) return
    var state = Model.entryState(entry, context).state
    var verb = (state === "active") ? "stop" : (state === "failed" ? "restart" : "start")
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
    } else {
      return
    }
    actionError = ""
    actionMessage = verb + " " + (entry.name || entry.unit || entry.name)
    actionProc.command = command
    actionProc.running = true
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

  Process {
    id: initProc
    command: ["/usr/bin/mkdir", "-p", services.configDir]
    onExited: {
      configFile.setText(Model.HEADER)
      services.applyConfig(Model.HEADER)
      services.tightenPermissions()
    }
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

const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../lib/Model.js")

function unitEntry(overrides) {
  return Object.assign(
    { type: "unit", scope: "system", unit: "docker.service", name: "docker" },
    overrides || {}
  )
}

test("a fresh config is only the header", () => {
  const parsed = Model.parseConfigText(Model.HEADER)
  assert.equal(parsed.entries.length, 0)
  assert.deepEqual(parsed.errors, [])
})

test("pin then unpin then pin is lossless", () => {
  const first = Model.pinText(Model.HEADER, unitEntry())
  const second = Model.pinText(first, unitEntry({ name: "containers" }))
  assert.equal(first, second, "pinning an already-pinned entry is a no-op")

  const unpinned = Model.unpinText(first, "unit:system:docker.service")
  assert.ok(unpinned.includes('// {"id":"unit:system:docker.service"'), unpinned)
  assert.equal(
    Model.parseConfigText(unpinned).entries[0].pinned,
    false,
    "commented entries are still parsed, as unpinned"
  )

  const repinned = Model.pinText(unpinned, unitEntry())
  assert.equal(repinned, first, "re-pin restores the original line byte for byte")
  assert.deepEqual(Model.parseConfigText(repinned).entries[0], Object.assign(unitEntry(), {
    id: "unit:system:docker.service",
    pinned: true
  }))
})

test("pin appends in one line and leaves comments alone", () => {
  const text = "# my notes\n// {\"id\":\"probe:nas:8096\",\"type\":\"probe\",\"host\":\"nas\",\"port\":8096,\"name\":\"Jellyfin\"}\n"
  const next = Model.pinText(text, unitEntry())
  const lines = next.trimEnd().split("\n")
  assert.equal(lines[0], "# my notes")
  assert.ok(lines[1].startsWith("// "))
  assert.equal(lines[2], '{"id":"unit:system:docker.service","type":"unit","scope":"system","unit":"docker.service","name":"docker"}')
})

test("unpin only touches the matching active line", () => {
  const a = Model.pinText(Model.HEADER, unitEntry())
  const b = Model.pinText(a, { type: "probe", host: "127.0.0.1", port: 8080, name: "web" })
  const unpinned = Model.unpinText(b, "probe:127.0.0.1:8080")
  assert.ok(unpinned.includes('{"id":"unit:system:docker.service"'))
  assert.ok(unpinned.includes('// {"id":"probe:127.0.0.1:8080"'))
  assert.equal(Model.unpinText(unpinned, "probe:127.0.0.1:8080").match(/^\/\/.*probe/gm).length, 1)
})

test("malformed lines are reported and do not hide valid ones", () => {
  const text = Model.HEADER + '{"id":"unit:system:docker.service","type":"unit","scope":"system","unit":"docker.service"}\nnot json\n{"type":"nope"}\n'
  const parsed = Model.parseConfigText(text)
  assert.equal(parsed.entries.length, 1)
  assert.equal(parsed.errors.length, 2)
  assert.equal(parsed.errors[0].line, 5)
  assert.equal(Model.configErrorsText(parsed.errors), "services.conf line 5: not valid JSON")
})

test("duplicate ids are rejected instead of silently merged", () => {
  const line = '{"id":"unit:system:docker.service","type":"unit","scope":"system","unit":"docker.service"}\n'
  const parsed = Model.parseConfigText(Model.HEADER + line + line)
  assert.equal(parsed.entries.length, 1)
  assert.equal(parsed.errors[0].message, "duplicate id")
})

test("unit names cannot smuggle options or paths", () => {
  const bad = [
    "-oProxyCommand=x.service",
    "../../etc/passwd.service",
    "docker.service; rm -rf /",
    "docker",
    "docker.service\n"
  ]
  for (const unit of bad) assert.notEqual(Model.validateEntry(unitEntry({ unit })), "", unit)

  assert.equal(Model.validateEntry(unitEntry({ unit: "tailscaled.service" })), "")
  assert.equal(Model.validateEntry(unitEntry({ scope: "user", unit: "rclone-a.service" })), "")
  assert.equal(Model.validateEntry(unitEntry({ scope: "root" })), "unit scope must be user or system")
})

test("probe entries validate host and port", () => {
  assert.equal(Model.validateEntry({ type: "probe", host: "nas.local", port: 8096 }), "")
  assert.equal(Model.validateEntry({ type: "probe", host: "192.0.2.10", port: 443 }), "")
  assert.notEqual(Model.validateEntry({ type: "probe", host: "host with space", port: 80 }), "")
  assert.notEqual(Model.validateEntry({ type: "probe", host: "ok", port: 0 }), "")
  assert.notEqual(Model.validateEntry({ type: "probe", host: "ok", port: 65536 }), "")
  assert.notEqual(Model.validateEntry({ type: "probe", host: "ok", port: 80.5 }), "")
  assert.notEqual(Model.validateEntry({ type: "probe", host: "ok", port: 80, scheme: "ftp" }), "")
})

test("ids are stable and scope-aware", () => {
  assert.equal(Model.entryId(unitEntry()), "unit:system:docker.service")
  assert.equal(Model.entryId(unitEntry({ scope: "user" })), "unit:user:docker.service")
  assert.equal(Model.entryId({ type: "container", name: "jellyfin" }), "container:jellyfin")
  assert.equal(Model.entryId({ type: "probe", host: "nas", port: 80 }), "probe:nas:80")
})

test("serialization is canonical and drops UI-only fields", () => {
  const line = Model.serializeEntry(Object.assign(unitEntry({ pinned: true, extra: "x" }), {
    stopUnits: ["docker.socket", "containerd.service"]
  }))
  assert.equal(
    line,
    '{"id":"unit:system:docker.service","type":"unit","scope":"system","unit":"docker.service","name":"docker","stopUnits":["docker.socket","containerd.service"]}'
  )
})

test("control characters never reach a label", () => {
  assert.equal(Model.cleanLabel("  evil\u0000\u001b[31mname\n\t"), "evil [31mname")
  assert.equal(Model.cleanLabel("x".repeat(100), 10).length, 10)
})

test("systemd json is parsed with scope and failure state", () => {
  const raw = JSON.stringify([
    { unit: "docker.service", load: "loaded", active: "active", sub: "running", description: "Docker" },
    { unit: "not-a-unit", load: "loaded", active: "active", sub: "running", description: "x" },
    { unit: "cups.service", load: "loaded", active: "inactive", sub: "failed", description: "Printing" }
  ])
  const units = Model.parseUnitsJson(raw, "system")
  assert.equal(units.length, 2)
  assert.equal(units[0].scope, "system")
  assert.equal(units[1].active, false)
  assert.deepEqual(Model.parseUnitsJson("garbage", "user"), [])
})

test("infrastructure units stay out of the machine list", () => {
  const units = [
    { name: "dbus-broker.service", label: "D-Bus", active: true, sub: "running", load: "loaded", scope: "user" },
    { name: "rclone-backup.service", label: "rclone backup", active: true, sub: "running", load: "loaded", scope: "user" },
    { name: "cups.service", label: "Printing", active: false, sub: "dead", load: "loaded", scope: "system" }
  ]
  const running = Model.machineRows([], units, [], [], false)
  assert.deepEqual(running.map(row => row.title), ["rclone-backup"])
  assert.equal(Model.isInfraUnit("gvfs-daemon.service"), true)
  assert.equal(Model.isInfraUnit("gvfsd.service"), false)
})

test("listeners without a unit become probes, not fake units", () => {
  const listeners = [
    { addr: "127.0.0.1", port: 5173, process: "node", pid: "42", unit: "", scope: "" },
    { addr: "0.0.0.0", port: 631, process: "", pid: "", unit: "cups.service", scope: "system" }
  ]
  const rows = Model.machineRows([], [], listeners, [], false)
  const local = rows.find(row => row.kind === "probe")
  assert.equal(local.id, "probe:127.0.0.1:5173")
  assert.equal(local.entry.host, "127.0.0.1")
  assert.equal(rows.find(row => row.id === "unit:system:cups.service").kind, "unit")
})

test("entry state comes from the matching scope only", () => {
  const ctx = {
    systemUnits: [{ name: "docker.service", active: true, sub: "running" }],
    userUnits: [{ name: "docker.service", active: false, sub: "failed" }],
    docker: { containers: [{ name: "jellyfin", state: "running" }] },
    probes: { "nas:8096": true, "nas:1": false }
  }
  assert.equal(Model.entryState(unitEntry(), ctx).state, "active")
  assert.equal(Model.entryState(unitEntry({ scope: "user" }), ctx).state, "failed")
  assert.equal(Model.entryState(unitEntry({ unit: "missing.service" }), ctx).state, "missing")
  assert.equal(Model.entryState({ type: "container", name: "jellyfin" }, ctx).state, "active")
  assert.equal(Model.entryState({ type: "container", name: "gone" }, ctx).state, "missing")
  assert.equal(Model.entryState({ type: "probe", id: "probe:nas:8096", host: "nas", port: 8096 }, ctx).state, "active")
  assert.equal(Model.entryState({ type: "probe", id: "probe:nas:1", host: "nas", port: 1 }, ctx).state, "inactive")
  assert.equal(Model.entryState({ type: "probe", id: "probe:nas:2", host: "nas", port: 2 }, ctx).state, "unknown")
})

test("probe pairs are only built for pinned probes", () => {
  const entries = [
    Object.assign({ type: "probe", host: "nas", port: 8096, pinned: true }, { id: "probe:nas:8096" }),
    Object.assign({ type: "unit", scope: "system", unit: "docker.service", pinned: true }, { id: "unit:system:docker.service" }),
    Object.assign({ type: "probe", host: "nas", port: 80, pinned: false }, { id: "probe:nas:80" })
  ]
  assert.equal(Model.probePairs(entries), "nas 8096")
  assert.deepEqual(Model.parseProbeJson('{"nas:8096":true}'), { "nas:8096": true })
  assert.deepEqual(Model.parseProbeJson("nope"), {})
})

test("network rows are pin-addressable and labelled by port when mDNS is silent", () => {
  const network = {
    hosts: [
      { ip: "192.0.2.10", name: "pi.tailnet.example", sources: ["tailscale"], services: [
        { port: 443, name: "", source: "probe" },
        { port: 8080, name: "", source: "probe" }
      ] }
    ]
  }
  const rows = Model.networkRows(network, [])
  assert.equal(rows[0].id, "probe:pi.tailnet.example:443")
  assert.equal(rows[0].title, "HTTPS")
  assert.equal(rows[0].action.url, "https://pi.tailnet.example/")
  assert.equal(rows[1].entry.scheme, undefined)
  assert.equal(rows.find(row => row.port === 443).entry.scheme, "https")
  assert.equal(Model.portLabel(8096), "Jellyfin")
  assert.equal(Model.portLabel(65535), "Port 65535")
  assert.equal(rows[0].pinnable, true)
})

test("Ollama on another host is labelled and openable", () => {
  const network = {
    hosts: [
      { ip: "192.0.2.10", name: "desktop.tailnet.example", sources: ["tailscale"], services: [
        { port: 11434, name: "", source: "probe" }
      ] }
    ]
  }
  const row = Model.networkRows(network, [])[0]
  assert.equal(row.title, "Ollama")
  assert.equal(row.id, "probe:desktop.tailnet.example:11434")
  assert.deepEqual(row.action, {
    kind: "open",
    label: "open",
    url: "http://desktop.tailnet.example:11434/"
  })
})

test("Synology DSM, Web Station, and the 5000 redirect are labelled", () => {
  const network = {
    hosts: [{
      ip: "192.0.2.20", name: "nas.local", sources: ["tailscale"], services: [
        { port: 80, name: "", source: "probe", server: "nginx",
          title: "Hello! Welcome to Synology Web Station!", synology: true },
        { port: 5000, name: "", source: "probe", server: "nginx", title: "", synology: false },
        { port: 5001, name: "", source: "probe", server: "nginx",
          title: "File Archive", synology: true },
        { port: 32400, name: "", source: "probe", server: "", title: "Unauthorized", synology: false }
      ]
    }]
  }
  const rows = Model.networkRows(network, [])
  const byPort = {}
  for (const row of rows) byPort[row.port] = row
  assert.equal(byPort[80].title, "Synology Web Station")
  assert.equal(byPort[5000].title, "Synology DSM")
  assert.match(byPort[5000].subtitle, /redirects to :5001/)
  assert.equal(byPort[5001].title, "File Archive")
  assert.match(byPort[5001].subtitle, /DSM web UI/)
  assert.equal(byPort[5001].entry.scheme, "https")
  assert.equal(byPort[5001].pinnable, true)
  assert.equal(byPort[32400].title, "Plex")
  assert.doesNotMatch(byPort[32400].subtitle, /DSM/)
})

test("AirPlay on port 5000 is labelled and not offered for pinning", () => {
  const network = {
    hosts: [{
      ip: "192.0.2.10", name: "mini.local", sources: ["tailscale"],
      services: [{ port: 5000, name: "", source: "probe", server: "AirTunes/950.7.1" }]
    }]
  }
  const rows = Model.networkRows(network, [])
  assert.equal(rows[0].title, "AirPlay Receiver")
  assert.equal(rows[0].pinnable, false)
  assert.match(rows[0].subtitle, /no web UI/)
  assert.equal(rows[0].entry.name, "AirPlay Receiver")
  assert.equal(rows[0].action, null)
  assert.equal(Model.isAirPlayServer("AirTunes/950.7.1"), true)
  assert.equal(Model.isAirPlayServer("nginx/1.24.0"), false)
})

test("pinned rows and summary report issues, not just presence", () => {
  const entries = [
    Object.assign(unitEntry({ name: "Docker" }), { id: "unit:system:docker.service", pinned: true }),
    Object.assign({ type: "probe", host: "nas", port: 80, name: "NAS" }, { id: "probe:nas:80", pinned: true }),
    Object.assign(unitEntry({ unit: "cups.service", name: "Printing" }), { id: "unit:system:cups.service", pinned: false })
  ]
  const ctx = {
    systemUnits: [{ name: "docker.service", active: true, sub: "running" }],
    probes: { "nas:80": false }
  }
  const rows = Model.pinnedRows(entries, ctx)
  assert.equal(rows.length, 2)
  assert.equal(rows[0].state, "active")
  assert.equal(rows[0].action, null)
  assert.equal(rows[1].stateLabel, "unreachable")
  assert.equal(rows[1].action.url, "http://nas/")
  assert.deepEqual(Model.summary(entries.filter(entry => entry.pinned), ctx), { total: 2, running: 1, issues: 1 })
})

test("docker containers appear as machine rows and pin like units", () => {
  const containers = [
    { name: "jellyfin", image: "jellyfin/jellyfin", state: "running", status: "Up 3 hours" },
    { name: "backup", image: "restic/restic", state: "exited", status: "Exited (0) 2 hours ago" }
  ]
  const rows = Model.machineRows([], [], [], [], false, containers)
  assert.equal(rows.length, 2)
  assert.equal(rows[0].kind, "container")
  assert.equal(rows[0].id, "container:jellyfin")
  assert.equal(rows[0].active, true)
  assert.match(rows[0].subtitle, /jellyfin\/jellyfin/)

  const next = Model.pinText(Model.HEADER, rows[0].entry)
  const parsed = Model.parseConfigText(next)
  assert.equal(parsed.entries[0].type, "container")
  assert.equal(parsed.entries[0].pinned, true)
  assert.equal(
    Model.entryState(parsed.entries[0], { docker: { containers } }).state,
    "active"
  )
  assert.equal(
    Model.entryState({ type: "container", name: "backup" }, { docker: { containers } }).label,
    "exited"
  )
})

test("probe actions open web pages and ssh terminals", () => {
  assert.equal(Model.probeProtocol(22), "ssh")
  assert.equal(Model.probeProtocol(443), "web")
  assert.equal(Model.probeProtocol(53), "")

  assert.deepEqual(
    Model.probeAction({ type: "probe", host: "192.0.2.10", port: 443 }),
    { kind: "open", label: "open", url: "https://192.0.2.10/" }
  )
  assert.equal(Model.probeAction({ type: "probe", host: "nas.local", port: 5001 }).url,
    "https://nas.local:5001/")
  assert.equal(Model.probeAction({ type: "probe", host: "nas.local", port: 80 }).url,
    "http://nas.local/")
  assert.equal(Model.probeAction({ type: "probe", host: "nas.local", port: 8080 }).url,
    "http://nas.local:8080/")
  assert.equal(Model.probeAction({ type: "probe", host: "nas.local", port: 9090 }).url,
    "https://nas.local:9090/")
  assert.deepEqual(
    Model.probeAction({ type: "probe", host: "nas.local", port: 22 }),
    { kind: "ssh", label: "ssh", host: "nas.local", port: 22 }
  )
  assert.equal(Model.probeAction({ type: "probe", host: "nas.local", port: 53 }), null)
  assert.equal(Model.probeAction({ type: "probe", host: "-oProxyCommand=x", port: 22 }), null)
  assert.equal(Model.probeAction({ type: "probe", host: "2001:db8::10", port: 8080 }).url,
    "http://[2001:db8::10]:8080/")
  assert.equal(
    Model.probeAction({ type: "probe", host: "nas.local", port: 443, path: "/admin/" }).url,
    "https://nas.local/admin/"
  )
  assert.equal(
    Model.validateEntry({ type: "probe", host: "nas.local", port: 443, path: "/admin/" }),
    ""
  )
  assert.equal(
    Model.validateEntry({ type: "probe", host: "nas.local", port: 443, path: "/admin login" }),
    "invalid path"
  )
  const roundTrip = Model.parseConfigText(Model.pinText(Model.HEADER, {
    type: "probe", host: "nas.local", port: 443, scheme: "https", path: "/admin/", name: "Admin"
  }))
  assert.equal(roundTrip.entries[0].path, "/admin/")
})

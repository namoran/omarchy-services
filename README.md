# Services

Curated system services in the Omarchy bar: pin the handful you actually care
about, see whether they are up, start, stop, or restart them, and discover what
is running on this machine and on your local network without opening a
dashboard.

Everything stays on the machine. There is no telemetry, no remote API, and no
background daemon.

## What it does

- **Pinned tab** — the services you chose, with live state and contextual
  action buttons. Clicking a filled star unpins; the line stays in the config
  as a comment so re-pinning is one click. Rows that need attention are tinted
  red, with a red dot and state text.
- **This machine** — running systemd units (system and user), plus unattributed
  listeners found through `ss`, plus Docker containers when the socket is
  readable.
- **Network** — an explicit scan of ARP neighbours, a whitelist of useful mDNS
  service types, and online Tailscale peers. Only private addresses are probed,
  and only a short fixed port list is checked.
- **Bar icon** — a gear that dims when nothing is running, turns red, and gains
  a small red dot when a pinned service is stopped, failed, or unreachable.
- **Actions** — web services get `open` (default browser), SSH gets `ssh` (a
  terminal), and running units/containers get `restart` alongside start/stop.
  Other ports get no open button rather than a misleading guess.

Units are started, stopped, and restarted through `systemctl` (system units
prompt through polkit). Containers use `docker start` / `docker stop` /
`docker restart`. Probes are plain TCP connects (plus a RakNet-style UDP ping
for Minecraft Bedrock); they only report reachability.

## Requirements

- Omarchy with the Quickshell-based shell.
- `bash`, `jq`, `systemctl`, `ss` (all part of a normal Omarchy install).
- Optional: `docker` and access to `/var/run/docker.sock` for containers.
- Optional: `avahi-browse` for mDNS names and ports.
- Optional: `tailscale` for tailnet peers.

Without the optional pieces the widget still works; it just shows fewer rows.

## Install

From a published repo:

```bash
omarchy plugin add <git-url> --enable
```

Or manually, for development:

```bash
git clone <git-url> ~/.config/omarchy/plugins/io.github.nam.services
cd ~/.config/omarchy/plugins/io.github.nam.services
omarchy plugin validate .
omarchy plugin enable io.github.nam.services --section right
```

The plugin folder must be a real directory. Omarchy's validator rejects
symlinks anywhere inside a plugin.

## Using it

Open the panel from the gear in the bar.

| Key | Action |
| --- | --- |
| `1` | Pinned tab |
| `2` | This machine tab |
| `3` | Network tab |
| `r` | Refresh local state |
| `s` | Start or cancel a network scan (Network tab) |
| `Esc` | Close |

Click a row's star to pin or unpin. Network rows are pinned by hostname when
mDNS or Tailscale provides one, otherwise by IP address. The buttons on each
row are context-sensitive: `open` for a web UI, `ssh` for a terminal, and
start/stop/restart for units and containers where those actions apply.

Right-clicking the bar icon refreshes without opening the panel.

## Configuration

`~/.config/omarchy/services.conf`, one JSON object per line. `#` lines are
comments. A line starting with `//` is an unpinned entry; it is parsed and kept
so the star can restore it.

```jsonc
# my services
{"id":"unit:system:docker.service","type":"unit","scope":"system","unit":"docker.service","name":"Docker"}
// {"id":"probe:media.local:8096","type":"probe","host":"media.local","port":8096,"scheme":"http","name":"Jellyfin"}
// {"id":"container:jellyfin","type":"container","name":"jellyfin","label":"Jellyfin"}
```

Three entry types are supported:

- `unit` — `scope` is `system` or `user`, `unit` must be a valid unit name.
  Optional `stopUnits` stops extra units first, e.g. `docker.socket`.
- `container` — Docker container name.
- `probe` — `host`, `port`, optional `scheme` (`http`/`https`), `path`, and
  `name`. `path` is used by the `open` button, e.g. `/admin/` for Pi-hole.
  Optional `proto: "udp"` probes with a Minecraft Bedrock RakNet ping instead
  of a TCP connect.
- `remote` — a control script on another machine: `host`, `user`, and an
  absolute `script` path, plus optional `probePort`/`probeProto` for the state
  probe. The widget runs exactly `ssh user@host -- script start|stop|restart`
  (never a shell string), and lets the script handle daemonising, PID files,
  and logging. When `host` resolves to this machine, the script runs locally
  instead of over SSH. This is how a Minecraft Bedrock server that you launch
  from a `.desktop` file — deliberately not a systemd unit — can still be
  started and stopped from any machine in your tailnet.

The file is created with mode `0600` and rewritten atomically. It can contain
private hostnames, so keep it out of version control. Malformed lines are
reported in the panel and the rest of the file still loads.

There is deliberately no `command` entry type: a widget that runs arbitrary
strings from a config file is a remote-code-execution footgun, not a feature.
The `remote` type is the narrow exception: the config names a script path, and
the validation regex guarantees it can never be more than that.

A minimal control script for a Bedrock-style server (`start` runs it detached
with `nohup`, `stop` sends SIGTERM with a 10 s grace period before SIGKILL,
`restart`, `status`) is the entire contract; the widget only ever appends one
of those four words.

## Network discovery

A scan is one explicit action, never a background sweep:

1. Read neighbours already in the ARP table (no packets).
2. Browse a whitelist of mDNS types: HTTP(S), SSH, SMB, NFS, IPP, Plex,
   Home Assistant, Syncthing, ESPHome, workstations, and a few printers.
   AirPlay, Chromecast, and companion-link noise is ignored.
3. Add online Tailscale peers.
4. Probe a fixed list of common ports (TCP, plus one UDP Bedrock ping) on at
   most 32 hosts, 32 connects at a time, with a 0.3 s timeout.
5. Read response headers and short page titles from at most 16 of those open
   web ports. That is how an AirPlay receiver on 5000 becomes “AirPlay
   Receiver”, and a Synology NAS becomes “Synology DSM” / “Synology Web
   Station” instead of a misleading “Dev server”.
6. Ask live Minecraft servers who they are: older Bedrock over a RakNet UDP
   ping (MOTD + player count), BDS 26.50+ over its NetherNet TCP signalling
   port 19132, where the same `/v1/join` request real clients make returns the
   server name, level, and player count as JSON. That is how a discovered
   server shows up as “MoranFamily · NetherNet · 0/10 players” instead of a
   bare port number.

Only RFC1918, loopback, Tailscale CGNAT, and IPv6 ULA/link-local addresses are
accepted. A poisoned mDNS record cannot turn the scan into an internet scanner.
Pinned probes may point at any host you configure yourself.

The scan takes a few seconds and can be cancelled from the panel.

## IPC

The panel is scriptable, and the same model validates every input:

```bash
omarchy-shell io.github.nam.services pin '{"type":"unit","scope":"system","unit":"docker.service","name":"Docker"}'
omarchy-shell io.github.nam.services unpin 'unit:system:docker.service'
omarchy-shell io.github.nam.services scan
omarchy-shell io.github.nam.services tab network
omarchy-shell io.github.nam.services status
```

`status` returns the pinned ids, summary counts, last probe results, and any
error.

## Agent access (MCP)

The plugin ships an MCP server (`mcp/server.js`) so AI agents — opencode,
Hermes, anything speaking MCP over stdio — can use the same tools the widget
uses: `services_status`, `services_machine`, `services_network`,
`services_action`, `services_pin`, `services_unpin`.

Agent control is gated by one switch, in the widget panel:

- **Agent access: off** (the default) — agents can look (status, machine,
  network) but every mutating call is refused with a pointer to the switch.
- **Agent access: on** — the widget creates the marker file
  `~/.config/omarchy/services-mcp-on`; the MCP server re-checks it on every
  mutating call, so toggling takes effect in already-running agent sessions
  with no restarts. The server keeps no state of its own.

The widget is the single switch by construction. Be aware of its limit: an
agent that already has unrestricted shell access on this machine could create
the marker file itself. The gate's value is no standing capability by default,
a deliberate visible opt-in, and protection for agents restricted to MCP-only
access — not containment for a shell-level adversary.

To register it:

```bash
opencode mcp add services --global -- node ~/.config/omarchy/plugins/io.github.nam.services/mcp/server.js
```

or, for Hermes-style YAML configs:

```yaml
mcp_servers:
  services:
    command: node
    args: ["~/.config/omarchy/plugins/io.github.nam.services/mcp/server.js"]
```

## Security notes

- `systemctl` and `docker` are invoked with argv arrays after regex validation;
  no discovered value is ever interpolated into a shell string. Remote actions
  run a fixed argv too: `ssh user@host -- script verb`.
- The MCP server is read-only by default and can only act after you flip the
  widget's Agent access switch; it re-verifies the gate on every mutation.
- The discovery script emits JSON only. Diagnostics go to stderr.
- Network results live in memory; only what you pin is written to disk.
- Status polling is a single `systemctl list-units` call every 15 seconds
  (configurable in the widget settings), not a daemon.
- There is no update checker, analytics, or crash reporting.

## Development

```bash
npm test                 # model, config round-trip, filters, AirPlay labelling, validation
bash -n lib/collect.sh   # discovery script syntax
npm run check:pii        # refuse private addresses, tailnet names, emails, MACs (tree + git history)
node --check mcp/server.js
omarchy plugin validate .
```

Layout:

- `Widget.qml` — bar icon, panel, keyboard handling, IPC.
- `Service.qml` — polling, config watch/write, actions, scans, agent-access gate.
- `lib/Model.js` — pure logic, also loaded by the Node tests and the MCP server.
- `lib/collect.sh` — local and network discovery, RakNet ping, NetherNet
  fingerprinting, probe-many.
- `mcp/server.js` — zero-dependency MCP stdio server reusing `lib/Model.js`.
- `test/model.test.js` — 28 tests.
- `examples/services.conf` — synthetic sample entries.

`scripts/check-pii.sh` scans everything that would be committed — and, inside
a git repo, every historical commit — and fails on home paths, private and
CGNAT addresses, tailnet names, email addresses, and MAC addresses. Run it
before every push.

## Limitations

- Docker requires either membership in the `docker` group or a rootless setup;
  otherwise the panel says so and lists no containers.
- mDNS discovery is intentionally a whitelist, not "every advertised service".
- Probe state means "TCP connect succeeded", not "the application is healthy".
- AirPlay receivers have no web page; a 403 on port 5000 is normal. They are
  labelled and shown without a pin star.
- One instance per shell; multiple widgets are disabled in the manifest.
- systemd actions follow polkit policy. Cancelling the prompt leaves the service
  untouched and the panel reports the failure.

## License

MIT. See `LICENSE`.

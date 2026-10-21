# Services

Curated system services in the Omarchy bar: pin the handful you actually care
about, see whether they are up, start or stop them, and discover what is running
on this machine and on your local network without opening a dashboard.

Everything stays on the machine. There is no telemetry, no remote API, and no
background daemon.

## What it does

- **Pinned tab** — the services you chose, with live state and start/stop
  buttons. Clicking a filled star unpins; the line stays in the config as a
  comment so re-pinning is one click.
- **This machine** — running systemd units (system and user), plus unattributed
  listeners found through `ss`, plus Docker containers when the socket is
  readable.
- **Network** — an explicit scan of ARP neighbours, a whitelist of useful mDNS
  service types, and online Tailscale peers. Only private addresses are probed,
  and only a short fixed port list is checked.
- **Bar icon** — a gear that dims when nothing is running and gains a small red
  dot when a pinned service is stopped, failed, or unreachable.

Units are started and stopped through `systemctl` (system units prompt through
polkit). Containers use `docker start` / `docker stop`. Probes are plain TCP
connects; they only report reachability.

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
mDNS or Tailscale provides one, otherwise by IP address.

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
- `probe` — `host`, `port`, optional `scheme` (`http`/`https`) and `name`.

The file is created with mode `0600` and rewritten atomically. It can contain
private hostnames, so keep it out of version control. Malformed lines are
reported in the panel and the rest of the file still loads.

There is deliberately no `command` entry type: a widget that runs arbitrary
strings from a config file is a remote-code-execution footgun, not a feature.

## Network discovery

A scan is one explicit action, never a background sweep:

1. Read neighbours already in the ARP table (no packets).
2. Browse a whitelist of mDNS types: HTTP(S), SSH, SMB, NFS, IPP, Plex,
   Home Assistant, Syncthing, ESPHome, workstations, and a few printers.
   AirPlay, Chromecast, and companion-link noise is ignored.
3. Add online Tailscale peers.
4. Probe 16 common ports on at most 32 hosts, 32 connects at a time, with a
   0.3 s timeout.
5. Read response headers and short page titles from at most 16 of those open
   web ports. That is how an AirPlay receiver on 5000 becomes “AirPlay
   Receiver”, and a Synology NAS becomes “Synology DSM” / “Synology Web
   Station” instead of a misleading “Dev server”.

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

## Security notes

- `systemctl` and `docker` are invoked with argv arrays after regex validation;
  no discovered value is ever interpolated into a shell string.
- The discovery script emits JSON only. Diagnostics go to stderr.
- Network results live in memory; only what you pin is written to disk.
- Status polling is a single `systemctl list-units` call every 15 seconds
  (configurable in the widget settings), not a daemon.
- There is no update checker, analytics, or crash reporting.

## Development

```bash
npm test                 # model, config round-trip, filters, AirPlay labelling, validation
bash -n lib/collect.sh   # discovery script syntax
npm run check:pii        # refuse private addresses, tailnet names, emails, MACs
omarchy plugin validate .
```

Layout:

- `Widget.qml` — bar icon, panel, keyboard handling, IPC.
- `Service.qml` — polling, config watch/write, actions, scans.
- `lib/Model.js` — pure logic, also loaded by the Node tests.
- `lib/collect.sh` — local and network discovery, probe-many.
- `test/model.test.js` — 21 tests.
- `examples/services.conf` — synthetic sample entries.

`scripts/check-pii.sh` scans everything that would be committed and fails on
home paths, private and CGNAT addresses, tailnet names, email addresses, and MAC
addresses. Run it before every push.

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

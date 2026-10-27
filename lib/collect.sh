#!/usr/bin/env bash
# Discovery helper for the Services bar widget.
#
# Everything sensitive is read here, on this machine, and printed as JSON on
# stdout. Nothing is cached, uploaded, or written to the config file.
#
#   collect.sh local        units, listeners, containers on this machine
#   collect.sh network      neighbours, mDNS services, tailnet peers, probes
#   collect.sh probe-many   reachability for "host port proto" triples
#   collect.sh ping-mc      one RakNet ping: "host port true|false"
#   collect.sh mc-info      Bedrock MOTD and player counts for one host:port
#
# The output of every command is a single JSON object. Diagnostics go to
# stderr; a failure never produces half a document.

set -uo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin"
export LC_ALL=C

PROBE_TIMEOUT="0.30"
NET_HOST_CAP=32
PROBE_PORTS=(22 53 80 443 3000 5000 5001 631 8000 8080 8096 8123 8443 9090 11434 19132 25565 19999 32400)
# TCP 19132 is the NetherNet signalling socket (BDS 26.50+); RakNet-era
# servers are UDP-only there, so the connect just fails. UDP 19132 answers
# the RakNet ping on older servers.
UDP_PORTS=(19132)
RAKNET_TIMEOUT="0.60"
# Only these open ports get an HTTP fingerprint. Kept small so a scan stays
# interactive even when several hosts hang instead of answering.
HTTP_PORTS=(80 443 3000 5000 5001 8000 8080 8096 8123 8443 9000 9090 19999 32400)
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

json_escape() { jq -Rr . <<<"${1:-}"; }

# avahi-browse escapes non-printable and separator characters as decimal
# \DDD sequences (e.g. \058 for ':'). Decode for display; the raw value never
# leaves this machine either way.
avahi_unescape() {
  local s="$1" out="" c n
  while [[ -n $s ]]; do
    c="${s:0:1}"
    if [[ $c == '\' ]]; then
      n="${s:1:3}"
      if [[ $n =~ ^[0-9]{3}$ ]]; then
        out+=$(printf "\\$(printf '%03o' "$((10#$n))")")
        s="${s:4}"
      else
        out+="${s:1:1}"
        s="${s:2}"
      fi
    else
      out+="$c"
      s="${s:1}"
    fi
  done
  printf '%s' "$out"
}

# Only service types a person would plausibly pin. AirPlay receivers, Google
# Casts, and companion links are deliberately excluded: they flood busy
# networks and are not services you start or stop.
is_useful_service_type() {
  case "$1" in
  _http._tcp | _https._tcp | _ssh._tcp | _sftp-ssh._tcp | _smb._tcp | _afpovertcp._tcp | \
    _nfs._tcp | _ipp._tcp | _ipps._tcp | _printer._tcp | _plexmediasvr._tcp | \
    _home-assistant._tcp | _syncthing._tcp | _esphomelib._tcp | _workstation._tcp | \
    _device-info._tcp | _rfb._tcp | _mqtt._tcp | _postgresql._tcp | _mysql._tcp) return 0 ;;
  *) return 1 ;;
  esac
}

# RFC1918, loopback, CGNAT (Tailscale), and IPv6 ULA/link-local only. Anything
# public is refused so a poisoned mDNS record cannot turn this into an internet
# scanner.
is_private_ip() {
  local ip="$1" a b c d
  if [[ $ip == *:* ]]; then
    case "$ip" in
    ::1 | fc* | fd* | fe80:*) return 0 ;;
    *) return 1 ;;
    esac
  fi
  IFS=. read -r a b c d <<<"$ip" || return 1
  [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $d =~ ^[0-9]+$ ]] || return 1
  ((a == 10)) && return 0
  ((a == 192 && b == 168)) && return 0
  ((a == 172 && b >= 16 && b <= 31)) && return 0
  ((a == 100 && b >= 64 && b <= 127)) && return 0
  ((a == 127)) && return 0
  return 1
}

is_safe_host() {
  [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,252}$ ]]
}

is_safe_port() {
  [[ ${1:-} =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

probe_port() {
  local host="$1" port="$2"
  timeout "$PROBE_TIMEOUT" bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$port" 2>/dev/null
}

# RakNet unconnected ping: the packet every Minecraft Bedrock server answers,
# and the only reliable UDP question here. Pure bash: /dev/udp needs no extra
# tools. The ping is ID_UNCONNECTED_PING + timestamp + magic + guid; the reply
# is 0x1c + echoed timestamp + magic + guid + a string carrying MOTD, version,
# and player counts.
raknet_packet() {
  printf '\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\x00\xfe\xfe\xfe\xfe\xfd\xfd\xfd\xfd\x12\x34\x56\x78\x12\x34\x56\x78\x00\x00\x00\x00'
}

raknet_ping() {
  local host="$1" port="$2" reply=""
  exec 3<>/dev/udp/"$host"/"$port" 2>/dev/null || return 1
  raknet_packet >&3 2>/dev/null || { exec 3>&- 3<&-; return 1; }
  # -N waits for 2048 bytes that never come, so this always burns the full
  # timeout — but bash keeps partial input in the variable on timeout, which
  # is exactly the one datagram we need. A one-byte read would return sooner
  # and throw the rest of the datagram away.
  IFS= read -r -t "$RAKNET_TIMEOUT" -N 2048 reply <&3 || true
  exec 3>&- 3<&-
  # A real reply starts with ID_UNCONNECTED_PING_OPEN_CONNECTIONS_REPLY (0x1c).
  [[ -n $reply && ${reply:0:1} == $'\x1c' ]] || return 1
  return 0
}

# Prints "host port true|false" per pair, the same line format the TCP probe
# loop produces, so callers can treat both uniformly.
cmd_ping_mc() {
  local host="${1:-}" port="${2:-}" up=false
  is_safe_host "$host" && is_safe_port "$port" || return 0
  raknet_ping "$host" "$port" && up=true
  printf '%s %s %s\n' "$host" "$port" "$up"
}

# Prints "ip<US>port<US>motd<US>players<US>max" for a live Bedrock server.
# Unit separators, not tabs: bash IFS collapsing would drop empty fields.
cmd_mc_info() {
  local ip="${1:-}" port="${2:-}" reply="" payload motd players max
  is_safe_host "$ip" || return 0
  is_safe_port "$port" || return 0
  [[ $ip == *:* ]] && return 0
  exec 3<>/dev/udp/"$ip"/"$port" 2>/dev/null || return 0
  raknet_packet >&3 2>/dev/null || { exec 3>&- 3<&-; return 0; }
  IFS= read -r -t "$RAKNET_TIMEOUT" -N 2048 reply <&3 || true
  exec 3>&- 3<&-
  [[ -n $reply && ${reply:0:1} == $'\x1c' ]] || return 0
  # 0x1c + 8-byte timestamp + 16-byte magic + 8-byte guid + 2-byte length.
  payload="${reply:35}"
  IFS=';' read -r _ motd _ _ players max <<<"$payload"
  motd=$(printf '%s' "${motd:-}" | tr -d '\r' | cut -c1-120)
  players=$(printf '%s' "${players:-}" | tr -cd '0-9')
  max=$(printf '%s' "${max:-}" | tr -cd '0-9')
  [[ -n $motd ]] || return 0
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$ip" "$port" "$motd" "${players:-0}" "${max:-0}"
}

# NetherNet (BDS 26.50+) answers the same join request real clients make:
# GET /v1/join on server-port, HTTP over TCP, JSON body. Prints
# "ip<US>port<US>name<US>level<US>players<US>max".
cmd_nether_info() {
  local ip="${1:-}" port="${2:-}" response name level players max
  is_safe_host "$ip" || return 0
  is_safe_port "$port" || return 0
  [[ $ip == *:* ]] && return 0
  response=$(curl -ksS -m 2 --max-filesize 20000 "http://$ip:$port/v1/join" 2>/dev/null)
  [[ -n $response ]] || return 0
  name=$(printf '%s' "$response" | jq -r '.name // empty' 2>/dev/null | cut -c1-120)
  [[ -n $name ]] || return 0
  level=$(printf '%s' "$response" | jq -r '.level // empty' 2>/dev/null | cut -c1-120)
  players=$(printf '%s' "$response" | jq -r '.players // 0' 2>/dev/null | tr -cd '0-9')
  max=$(printf '%s' "$response" | jq -r '.maxPlayers // 0' 2>/dev/null | tr -cd '0-9')
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$ip" "$port" "$name" "$level" "${players:-0}" "${max:-0}"
}

unit_from_pid() {
  local pid="$1" cg seg
  [[ -n $pid && -r /proc/$pid/cgroup ]] || return 0
  cg=$(tail -n 1 "/proc/$pid/cgroup" 2>/dev/null) || return 0
  seg="${cg##*/}"
  [[ $seg == *.service || $seg == *.scope ]] || return 0
  if [[ $cg == /user.slice/* ]]; then
    printf '%s\tuser\n' "$seg"
  else
    printf '%s\tsystem\n' "$seg"
  fi
}

collect_listeners() {
  local rows=()
  local line st rq sq local_addr peer rest port addr pid proc_name unit scope
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    read -r st rq sq local_addr peer rest <<<"$line"
    [[ -n ${local_addr:-} ]] || continue
    port="${local_addr##*:}"
    is_safe_port "$port" || continue
    # Ephemeral ports are usually internal plumbing (PipeWire, portals), not
    # something a person pins.
    ((10#$port >= 32768)) && continue
    addr="${local_addr%:*}"
    addr="${addr#[}"; addr="${addr%]}"; addr="${addr%%%*}"
    pid=""
    proc_name=""
    if [[ ${rest:-} =~ pid=([0-9]+) ]]; then pid="${BASH_REMATCH[1]}"; fi
    if [[ ${rest:-} =~ \"([^\"]+)\" ]]; then proc_name="${BASH_REMATCH[1]}"; fi
    unit=""; scope=""
    if [[ -n $pid ]]; then
      IFS=$'\t' read -r unit scope <<<"$(unit_from_pid "$pid")"
    fi
    rows+=("$(jq -nc \
      --arg addr "$addr" --argjson port "$((10#$port))" \
      --arg process "$proc_name" --arg pid "$pid" \
      --arg unit "$unit" --arg scope "$scope" \
      '{addr:$addr, port:$port,
        process:(if $process == "" then "" else $process end),
        pid:$pid, unit:$unit, scope:$scope}')")
  done < <(ss -ltnpH 2>/dev/null | head -n 200)
  if ((${#rows[@]} == 0)); then
    printf '[]\n'
    return
  fi
  printf '%s\n' "${rows[@]}" |
    jq -s 'unique_by(.addr + ":" + (.port|tostring) + ":" + .process) | sort_by(.port)'
}

collect_docker() {
  local out rc reason=""
  if ! command -v docker >/dev/null 2>&1; then
    jq -nc '{available:false, reason:"docker not installed", containers:[]}'
    return
  fi
  out=$(timeout 3 docker ps --format '{{json .}}' 2>&1)
  rc=$?
  if ((rc != 0)); then
    reason=$(printf '%s' "$out" | head -c 200 | tr '\n' ' ')
    jq -nc --arg reason "$reason" '{available:false, reason:$reason, containers:[]}'
    return
  fi
  if [[ -z $out ]]; then
    jq -nc '{available:true, reason:"", containers:[]}'
    return
  fi
  printf '%s\n' "$out" | jq -s '{
    available: true,
    reason: "",
    containers: [.[] | {
      name: (.Names // ""),
      image: (.Image // ""),
      state: (.State // ""),
      status: (.Status // ""),
      ports: (.Ports // "")
    }]
  }'
}

cmd_local() {
  local system_units user_units listeners docker warnings="[]"
  system_units=$(systemctl list-units --type=service --all --output=json --no-pager 2>/dev/null)
  [[ -n $system_units ]] || system_units='[]'
  user_units=$(systemctl --user list-units --type=service --all --output=json --no-pager 2>/dev/null)
  [[ -n $user_units ]] || user_units='[]'
  printf '%s' "$system_units" | jq -e 'type == "array"' >/dev/null 2>&1 || system_units='[]'
  printf '%s' "$user_units" | jq -e 'type == "array"' >/dev/null 2>&1 || user_units='[]'
  listeners=$(collect_listeners)
  docker=$(collect_docker)
  jq -nc \
    --argjson systemUnits "$system_units" \
    --argjson userUnits "$user_units" \
    --argjson listeners "$listeners" \
    --argjson docker "$docker" \
    --argjson warnings "$warnings" \
    '{systemUnits:$systemUnits, userUnits:$userUnits, listeners:$listeners,
      docker:$docker, warnings:$warnings}'
}

cmd_network() {
  local records="" warnings=() arp_ips avahi_missing=0 tailscale_missing=0
  local ip name port host svc_name source line
  local -a probe_hosts=()
  local -A advertised=()

  command -v avahi-browse >/dev/null 2>&1 || avahi_missing=1
  command -v tailscale >/dev/null 2>&1 || tailscale_missing=1

  # 1. Neighbours already in the ARP table: zero packets.
  while IFS= read -r ip; do
    is_private_ip "$ip" || continue
    records+=$(jq -nc --arg ip "$ip" '{kind:"host", ip:$ip, name:"", source:"arp"}')$'\n'
    probe_hosts+=("$ip")
  done < <(ip -j neigh 2>/dev/null |
    jq -r '.[] | select((.state // "") | test("FAILED|INCOMPLETE") | not) | .dst' 2>/dev/null)

  # 2. mDNS / DNS-SD: names and ports without touching every address.
  if ((avahi_missing == 0)); then
    while IFS=';' read -r tag iface proto name type domain host addr port txt; do
      [[ ${tag:-} == "=" ]] || continue
      is_useful_service_type "${type:-}" || continue
      is_private_ip "${addr:-}" || continue
      is_safe_port "${port:-}" || continue
      name=$(avahi_unescape "$name")
      host=$(avahi_unescape "$host")
      records+=$(jq -nc --arg ip "$addr" --arg name "$host" \
        '{kind:"host", ip:$ip, name:$name, source:"mdns"}')$'\n'
      records+=$(jq -nc --arg ip "$addr" --argjson port "$((10#$port))" \
        --arg name "$name" --arg type "$type" \
        '{kind:"svc", ip:$ip, port:$port, name:$name, source:"mdns", type:$type}')$'\n'
      advertised["$addr:$((10#$port))"]=1
      case " ${probe_hosts[*]-} " in *" $addr "*) ;; *) probe_hosts+=("$addr") ;; esac
    done < <(timeout 8 avahi-browse -artp 2>/dev/null | grep '^=;' || true)
  else
    warnings+=("avahi-browse is not installed; mDNS services are not listed")
  fi

  # 3. Tailnet peers: names, no port scan. Pinning one probes it explicitly.
  if ((tailscale_missing == 0)); then
    while IFS=$'\t' read -r ip name; do
      [[ -n ${ip:-} ]] || continue
      records+=$(jq -nc --arg ip "$ip" --arg name "$name" \
        '{kind:"host", ip:$ip, name:$name, source:"tailscale"}')$'\n'
      case " ${probe_hosts[*]-} " in *" $ip "*) ;; *) probe_hosts+=("$ip") ;; esac
    done < <(timeout 3 tailscale status --json 2>/dev/null |
      jq -r '[.Peer[]? | select(.Online == true)
        | {ip: ([.TailscaleIPs[]? | select(test("^100\\."))][0]),
           name: (.DNSName // .HostName // "")}]
        | .[] | select(.ip != null)
        | "\(.ip)\t\(.name | sub("\\.$"; ""))"' 2>/dev/null)
  fi

  # 4. Probe a short, fixed port list on already-discovered hosts only.
  local -a pairs=() udp_pairs=()
  local count=0
  for ip in "${probe_hosts[@]}"; do
    ((count++ >= NET_HOST_CAP)) && break
    is_private_ip "$ip" || continue
    for port in "${PROBE_PORTS[@]}"; do
      [[ -n ${advertised["$ip:$port"]+x} ]] && continue
      pairs+=("$ip $port")
    done
    for port in "${UDP_PORTS[@]}"; do
      udp_pairs+=("$ip $port")
    done
  done
  local -a opened=() udp_opened=()
  if ((${#pairs[@]} > 0)); then
    local open_out
    open_out=$(printf '%s\n' "${pairs[@]}" |
      xargs -P 32 -n 2 bash -c 'timeout 0.3 bash -c '"'"'exec 3<>/dev/tcp/"$1"/"$2"'"'"' _ "$0" "$1" 2>/dev/null && printf "%s %s\n" "$0" "$1"' 2>/dev/null || true)
    while read -r ip port; do
      [[ -n ${ip:-} && -n ${port:-} ]] || continue
      records+=$(jq -nc --arg ip "$ip" --argjson port "$port" \
        '{kind:"svc", ip:$ip, port:$port, name:"", source:"probe"}')$'\n'
      opened+=("$ip $port")
    done <<<"$open_out"
  fi
  if ((${#udp_pairs[@]} > 0)); then
    local udp_out
    udp_out=$(printf '%s\n' "${udp_pairs[@]}" |
      xargs -P 16 -n 2 bash "$SELF" ping-mc 2>/dev/null || true)
    while IFS=' ' read -r ip port up; do
      [[ -n ${ip:-} && -n ${port:-} && $up == true ]] || continue
      records+=$(jq -nc --arg ip "$ip" --argjson port "$port" \
        '{kind:"svc", ip:$ip, port:$port, name:"", source:"probe", proto:"udp"}')$'\n'
      udp_opened+=("$ip $port")
    done <<<"$udp_out"
  fi

  # 5. Ask open web-ish ports who they are. This is what distinguishes an
  # AirPlay receiver on 5000 from a real app. Capped and parallel.
  local -a fingerprint_pairs=()
  local entry
  for entry in "${opened[@]}"; do
    read -r ip port <<<"$entry"
    case " ${HTTP_PORTS[*]} " in *" $port "*) ;; *) continue ;; esac
    fingerprint_pairs+=("$ip $port")
  done
  ((${#fingerprint_pairs[@]} > 16)) && fingerprint_pairs=("${fingerprint_pairs[@]:0:16}")
  if ((${#fingerprint_pairs[@]} > 0)); then
    while IFS=$'\x1f' read -r ip port server title synology; do
      [[ -n ${ip:-} && -n ${port:-} ]] || continue
      records+=$(jq -nc --arg ip "$ip" --argjson port "$port" \
        --arg server "${server:-}" --arg title "${title:-}" --argjson synology "${synology:-0}" \
        '{kind:"fingerprint", ip:$ip, port:$port, server:$server, title:$title,
          synology:($synology == 1)}')$'\n'
    done < <(printf '%s\n' "${fingerprint_pairs[@]}" |
      xargs -P 8 -n 2 bash "$SELF" fingerprint 2>/dev/null)
  fi

  # 5b. Ask live Bedrock pings who they are. The MOTD becomes the row title
  # and the player counts reach the subtitle.
  if ((${#udp_opened[@]} > 0)); then
    local -a mc_pairs=("${udp_opened[@]:0:16}")
    while IFS=$'\x1f' read -r ip port motd players max; do
      [[ -n ${ip:-} && -n ${port:-} ]] || continue
      records+=$(jq -nc --arg ip "$ip" --argjson port "$port" \
        --arg title "${motd:-}" --argjson players "${players:-0}" --argjson max "${max:-0}" \
        '{kind:"mcinfo", ip:$ip, port:$port, title:$title,
          players:$players, maxPlayers:$max}')$'\n'
    done < <(printf '%s\n' "${mc_pairs[@]}" |
      xargs -P 8 -n 2 bash "$SELF" mc-info 2>/dev/null)
  fi

  # 5c. Ask open TCP 19132 ports (NetherNet signalling, BDS 26.50+) who they
  # are via the same /v1/join request real clients make.
  local -a nether_pairs=()
  for entry in "${opened[@]}"; do
    read -r ip port <<<"$entry"
    [[ $port == 19132 ]] || continue
    nether_pairs+=("$ip $port")
  done
  if ((${#nether_pairs[@]} > 0)); then
    while IFS=$'\x1f' read -r ip port name level players max; do
      [[ -n ${ip:-} && -n ${port:-} ]] || continue
      records+=$(jq -nc --arg ip "$ip" --argjson port "$port" \
        --arg title "${name:-}" --arg level "${level:-}" \
        --argjson players "${players:-0}" --argjson max "${max:-0}" \
        '{kind:"mcinfo", ip:$ip, port:$port, title:$title, level:$level,
          players:$players, maxPlayers:$max}')$'\n'
    done < <(printf '%s\n' "${nether_pairs[@]}" |
      xargs -P 8 -n 2 bash "$SELF" nether-info 2>/dev/null)
  fi

  local merged
  merged=$(printf '%s' "$records" | jq -s '
    reduce .[] as $r ({};
      if $r.kind == "host" then
        .[$r.ip] = (.[$r.ip] // {ip:$r.ip, name:"", sources:[], services:[]})
        | .[$r.ip].sources = ((.[$r.ip].sources + [$r.source]) | unique)
        | if (.[$r.ip].name == "" and $r.name != "") then .[$r.ip].name = $r.name else . end
      elif $r.kind == "svc" then
        .[$r.ip] = (.[$r.ip] // {ip:$r.ip, name:"", sources:[], services:[]})
        | if ([.[$r.ip].services[] | select(.port == $r.port)] | length) == 0
          then .[$r.ip].services += [{port:$r.port, name:($r.name // ""), source:($r.source // "probe"), proto:($r.proto // "tcp")}]
          else . end
      elif $r.kind == "fingerprint" then
        .[$r.ip] = (.[$r.ip] // {ip:$r.ip, name:"", sources:[], services:[]})
        | .[$r.ip].services = ([.[$r.ip].services[]
            | if .port == $r.port then . + {server:$r.server, title:$r.title, synology:$r.synology} else . end])
      elif $r.kind == "mcinfo" then
        .[$r.ip] = (.[$r.ip] // {ip:$r.ip, name:"", sources:[], services:[]})
        | .[$r.ip].services = ([.[$r.ip].services[]
            | if .port == $r.port then . + {title:$r.title, level:($r.level // ""), players:$r.players, maxPlayers:$r.maxPlayers} else . end])
      else . end)
    | [ .[] | select((.services | length) > 0) ]
    | map(.services |= sort_by(.port))
    | sort_by(.ip)
  ' 2>/dev/null)
  [[ -n $merged ]] || merged='[]'

  local warnings_json
  if ((${#warnings[@]})); then
    warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
  else
    warnings_json='[]'
  fi

  jq -nc --argjson hosts "$merged" --argjson warnings "$warnings_json" \
    --argjson probed "${#pairs[@]}" \
    '{hosts:$hosts, warnings:$warnings, probes:$probed, scannedAt:(now|floor)}'
}

# Reads response headers and the page title from a suspected web port.
# Prints "ip<US>port<US>Server<US>Title<US>synology" where US is the unit
# separator (an empty tab-separated field would be lost to IFS collapsing).
# AirPlay answers with an AirTunes server header; Synology pages mention
# their vendor name, which is how the panel stops calling them dev servers.
cmd_fingerprint() {
  local ip="${1:-}" port="${2:-}" scheme=http response server title synology
  is_safe_host "$ip" || return 0
  is_safe_port "$port" || return 0
  [[ $ip == *:* ]] && return 0
  case "$port" in 443 | 8443 | 5001) scheme=https ;; esac
  response=$(curl -ksS -m 2 -D - --max-filesize 200000 "$scheme://$ip:$port/" 2>/dev/null)
  [[ -n $response ]] || return 0
  server=$(printf '%s\n' "$response" |
    awk 'BEGIN { IGNORECASE = 1 } /^server:/ { sub(/^[Ss]erver:[ ]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }')
  title=$(printf '%s' "$response" |
    awk 'BEGIN { body = 0 } body { print } /^\r?$/ { body = 1 }' |
    tr '\n\r\t' '    ' |
    sed -n 's:.*<title[^>]*>\([^<]*\)</title>.*:\1:p' | head -n 1 |
    sed -e 's/&nbsp;/ /g' -e 's/&amp;/\&/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" |
    tr -s ' ' | sed 's/^ //; s/ $//' | cut -c1-200)
  synology=0
  printf '%s' "$response" | grep -qi 'synology' && synology=1
  [[ -n $server || -n $title || $synology == 1 ]] || return 0
  # Unit separator, not a tab: bash collapses runs of whitespace IFS, which
  # would silently drop empty server/title fields.
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$ip" "$port" "$server" "$title" "$synology"
}

cmd_probe_many() {
  local lines=() host port proto key up
  local out=""
  # Arguments may be supplied as "host port proto" triples so callers do not
  # have to keep stdin open (Quickshell's Process has no close-stdin call).
  # Two-token legacy pairs are treated as tcp.
  if (($# > 0)); then
    while (($# >= 3)); do
      host="$1"
      port="$2"
      proto="$3"
      shift 3
      [[ $proto == tcp || $proto == udp ]] || continue
      is_safe_host "$host" && is_safe_port "$port" && lines+=("$host $port $proto")
    done
    if (($# >= 2)); then
      host="$1"
      port="$2"
      is_safe_host "$host" && is_safe_port "$port" && lines+=("$host $port tcp")
    fi
  else
    while read -r host port proto; do
      [[ $proto == tcp || $proto == udp ]] || proto=tcp
      is_safe_host "$host" && is_safe_port "$port" && lines+=("$host $port $proto")
    done
  fi
  if ((${#lines[@]} == 0)); then
    printf '{}\n'
    return
  fi
  # Cap the working set: the panel never needs more than this at once.
  local -a tcp_pairs=() udp_pairs=()
  local item
  for item in "${lines[@]:0:100}"; do
    read -r host port proto <<<"$item"
    if [[ $proto == udp ]]; then
      udp_pairs+=("$host $port")
    else
      tcp_pairs+=("$host $port")
    fi
  done
  out=""
  if ((${#tcp_pairs[@]} > 0)); then
    out=$(printf '%s\n' "${tcp_pairs[@]}" |
      xargs -P 16 -n 2 bash -c '
        host="$0"; port="$1"
        if timeout 0.6 bash -c '"'"'exec 3<>/dev/tcp/"$1"/"$2"'"'"' _ "$host" "$port" 2>/dev/null
        then printf "%s %s true\n" "$host" "$port"
        else printf "%s %s false\n" "$host" "$port"
        fi' 2>/dev/null)
  fi
  if ((${#udp_pairs[@]} > 0)); then
    while IFS=' ' read -r host port up; do
      [[ -n ${host:-} && -n ${port:-} && -n ${up:-} ]] || continue
      out+="udp:$host $port $up"$'\n'
    done < <(printf '%s\n' "${udp_pairs[@]}" | xargs -P 16 -n 2 bash "$SELF" ping-mc 2>/dev/null)
  fi
  printf '%s\n' "$out" |
    awk 'NF==3 {printf "{\"key\":\"%s:%s\",\"up\":%s}\n", $1, $2, $3}' |
    jq -s 'map({(.key): .up}) | add // {}'
}

case "${1:-}" in
local) cmd_local ;;
network) cmd_network ;;
probe-many)
  shift || true
  cmd_probe_many "$@"
  ;;
fingerprint)
  shift || true
  cmd_fingerprint "$@"
  ;;
ping-mc)
  shift || true
  cmd_ping_mc "$@"
  ;;
mc-info)
  shift || true
  cmd_mc_info "$@"
  ;;
nether-info)
  shift || true
  cmd_nether_info "$@"
  ;;
version) printf '{"version":"0.5.0"}\n' ;;
*)
  printf 'usage: collect.sh {local|network|probe-many|fingerprint|ping-mc|mc-info|nether-info|version}\n' >&2
  exit 2
  ;;
esac

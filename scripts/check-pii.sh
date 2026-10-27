#!/usr/bin/env bash
# Refuses to let machine-local data reach a public push.
#
# The widget itself stores nothing: everything sensitive lives in
# ~/.config/omarchy/services.conf, outside this repo. This check covers the
# files that do ship: absolute home paths, private/CGNAT addresses, tailnet
# names, email addresses, and MAC addresses. Inside a git repo it also scans
# all of history, because scrubbing a file today does not scrub old commits.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

status=0
report() {
  local label="$1" hits="$2"
  if [[ -n $hits ]]; then
    printf 'check-pii: %s\n%s\n\n' "$label" "$hits"
    status=1
  fi
}

if git rev-parse --git-dir >/dev/null 2>&1; then
  FILES=$(git ls-files --cached --others --exclude-standard)
else
  FILES=$(find . -type f -not -path './.git/*')
fi
FILES=$(printf '%s\n' "$FILES" | grep -v '^scripts/check-pii.sh$' | grep -v '^$')

if [[ -n $FILES ]] && printf '%s\n' "$FILES" | grep -qx 'services.conf'; then
  echo "check-pii: services.conf is tracked; it is machine-local" >&2
  status=1
fi

scan_files() {
  local label="$1" pattern="$2"
  [[ -n $FILES ]] || return 0
  report "$label" \
    "$(printf '%s\n' "$FILES" | xargs -r grep -nIE "$pattern" -- 2>/dev/null)"
}

scan_files "absolute home path" '/home/[A-Za-z0-9._-]+'
scan_files "RFC1918 address" \
  '(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})'
scan_files "Tailscale CGNAT address" \
  '(^|[^0-9])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'
scan_files "tailnet name" '\.ts\.net'
scan_files "email address" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
scan_files "MAC address" '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'

# History: a value that was ever committed is still on every clone. Patterns
# are written so the grep source itself never matches (escaped dots, no
# literal examples). The checker excludes itself from the file scan above;
# here the same exclusion keeps its own pattern text out of the diff scan.
if git rev-parse --git-dir >/dev/null 2>&1; then
  HISTORY=$(git log -p --all -- . ':(exclude)scripts/check-pii.sh' 2>/dev/null)
  report "history: absolute home path" \
    "$(printf '%s\n' "$HISTORY" | grep -nIE '/home/[A-Za-z0-9._-]+' 2>/dev/null | head -5)"
  report "history: private address" \
    "$(printf '%s\n' "$HISTORY" | grep -nIE '(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|(^|[^0-9])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3})' 2>/dev/null | head -5)"
  report "history: tailnet name or MAC" \
    "$(printf '%s\n' "$HISTORY" | grep -nIE '\.ts\.net|([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' 2>/dev/null | head -5)"
fi

if ((status != 0)); then
  echo "check-pii: remove the values above before publishing" >&2
  exit 1
fi

echo "check-pii: clean"

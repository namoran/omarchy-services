#!/usr/bin/env bash
# Refuses to let machine-local data reach a public push.
#
# The widget itself stores nothing: everything sensitive lives in
# ~/.config/omarchy/services.conf, outside this repo. This check covers the
# files that do ship: absolute home paths, private/CGNAT addresses, tailnet
# names, email addresses, and MAC addresses.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

if git rev-parse --git-dir >/dev/null 2>&1; then
  FILES=$(git ls-files --cached --others --exclude-standard)
else
  FILES=$(find . -type f -not -path './.git/*')
fi
FILES=$(printf '%s\n' "$FILES" | grep -v '^scripts/check-pii.sh$' | grep -v '^$')

if [[ -z $FILES ]]; then
  echo "check-pii: no files to scan" >&2
  exit 0
fi

status=0
report() {
  local label="$1" hits="$2"
  if [[ -n $hits ]]; then
    printf 'check-pii: %s\n%s\n\n' "$label" "$hits"
    status=1
  fi
}

if printf '%s\n' "$FILES" | grep -qx 'services.conf'; then
  echo "check-pii: services.conf is tracked; it is machine-local" >&2
  status=1
fi

report "absolute home path" \
  "$(printf '%s\n' "$FILES" | xargs -r grep -nIE '/home/[A-Za-z0-9._-]+' -- 2>/dev/null)"

report "RFC1918 address" \
  "$(printf '%s\n' "$FILES" | xargs -r grep -nIE '(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})' -- 2>/dev/null)"

report "Tailscale CGNAT address" \
  "$(printf '%s\n' "$FILES" | xargs -r grep -nIE '(^|[^0-9])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}' -- 2>/dev/null)"

report "tailnet name" \
  "$(printf '%s\n' "$FILES" | xargs -r grep -nIE '\.ts\.net' -- 2>/dev/null)"

report "email address" \
  "$(printf '%s\n' "$FILES" | xargs -r grep -nIE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -- 2>/dev/null)"

report "MAC address" \
  "$(printf '%s\n' "$FILES" | xargs -r grep -nIE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' -- 2>/dev/null)"

if ((status != 0)); then
  echo "check-pii: remove the values above before publishing" >&2
  exit 1
fi

echo "check-pii: clean"

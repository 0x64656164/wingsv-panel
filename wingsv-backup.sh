#!/usr/bin/env bash
# wingsv-backup.sh - offline backup of a WINGS panel host.
#
#   sudo bash wingsv-backup.sh [output.tar.gz]
#
# The path list is discovered, not guessed: every path either config names or
# acme.sh keeps is picked up, so a certificate outside /etc/wings (install.sh
# option 2 lets you point TLS_CERT/TLS_KEY anywhere) still gets archived.
# Services are stopped first so SQLite and the config are flushed, and they are
# always restarted - even when archiving fails.

set -euo pipefail

PANEL_SVC=wingsv-panel
VKTP_SVC=wings-vktp
SVC_USER=wings
PANEL_CFG=/etc/wings/panel/config.toml
VKTP_CFG=/etc/wings/vktp/config.toml
OUT="${1:-/root/wingsv-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$PANEL_CFG" ] || { echo "no $PANEL_CFG - is this a panel host?" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }

warn() { printf '==> warn %s\n' "$*" >&2; }

# Same parser install.sh uses for its own config keys.
cfg_get() { # cfg_get <file> <key>
  [ -n "${2:-}" ] || return 0
  sed -n "s/^$2[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p" "$1" 2>/dev/null | head -1
}

# The database is needed explicitly: it is verified before and after archiving.
DB_PATH=$(cfg_get "$PANEL_CFG" DB_PATH)
[ -n "$DB_PATH" ] || DB_PATH=/var/lib/wings/panel/v-wingsnet.db

# Paths are archived relative to / so tar does not warn about leading slashes
# and the archive extracts with a plain `tar -xzf ... -C /`.
PATHS=()
MISSING=()
covered() { # covered <rel> - true when an already-added directory contains it
  local c
  for c in ${PATHS[@]+"${PATHS[@]}"}; do
    case "$1/" in "$c"/*) return 0;; esac
  done
  return 1
}
push() { # push <absolute path>
  local rel=${1#/}
  # Already inside an archived directory: adding it again would store it twice.
  if covered "$rel"; then return 0; fi
  PATHS+=("$rel")
}
usable() { # usable <absolute path> - reject relative paths and self-inclusion
  case "$1" in
    /*) ;;
    *) warn "config names a non-absolute path, skipped: '$1'"; return 1;;
  esac
  # Never archive a directory that contains the archive being written: that is
  # what makes tar abort with "file changed as we read it".
  case "$OUT/" in "$1"/*) warn "skipped $1 - it contains the output archive"; return 1;; esac
  return 0
}
add_path() { # config-named path: absent is tolerated, but reported
  usable "$1" || return 0
  if [ ! -e "$1" ]; then MISSING+=("$1"); return 0; fi
  push "$1"
}
add_base() { # path the install cannot run without: absent is fatal
  [ -e "$1" ] || { echo "ERROR: $1 is missing - nothing to back up" >&2; exit 1; }
  usable "$1" || return 0
  push "$1"
}

add_base /etc/wings
add_base /var/lib/wings
add_path "$(dirname "$DB_PATH")"   # custom DB_PATH from --advanced
add_path "$(cfg_get "$PANEL_CFG" CA_DIR)"        # /etc/wings/panel/certs
add_path "$(cfg_get "$PANEL_CFG" TLS_CERT)"      # may live outside /etc/wings
add_path "$(cfg_get "$PANEL_CFG" TLS_KEY)"
add_path "$(cfg_get "$VKTP_CFG" wg-key-file)"    # WireGuard private key

# acme.sh: keep its STATE, not its distribution. dnsapi/, deploy/ and notify/
# are ~300 re-downloadable files; renewal only needs the account key and this
# host's own certificate directory.
ACME_H=""
for h in "${ACME_HOME:-}" "$HOME/.acme.sh" /root/.acme.sh; do
  if [ -n "$h" ] && [ -d "$h" ]; then ACME_H="$h"; break; fi
done
if [ -n "$ACME_H" ]; then
  # The certificate directory is named after the domain acme.sh was asked for,
  # which is the PUBLIC_BASE_URL host: <domain> for RSA, <domain>_ecc for ECC.
  HOST=$(cfg_get "$PANEL_CFG" PUBLIC_BASE_URL)
  HOST=${HOST#*://}; HOST=${HOST%%/*}; HOST=${HOST%%:*}
  found=0
  for d in "$ACME_H/$HOST" "$ACME_H/${HOST}_ecc"; do
    [ -d "$d" ] && { add_path "$d"; found=1; }
  done
  if [ "$found" = 0 ]; then
    # Never drop the renewal state silently: if the domain does not line up
    # (cert for another host, DNS challenge, acme.sh name escaping) take every
    # certificate directory except the program's own subdirectories.
    warn "no acme.sh certificate directory matched '$HOST' - archiving all of them"
    for d in "$ACME_H"/*_ecc "$ACME_H"/*/; do
      [ -d "$d" ] || continue
      case "$(basename "$d")" in dnsapi|deploy|notify|bin|ca) continue;; esac
      [ -f "$d"/*.key ] || continue   # a certificate dir has a private key
      add_path "$d"
    done
  fi
  # The CA account is shared by every certificate acme.sh issues for this host;
  # without it renewal re-registers and can hit Let's Encrypt's new-subscriber
  # rate limit.
  add_path "$ACME_H/ca"
  add_path "$ACME_H/account.conf"
  add_path "$ACME_H/acme.sh.env"
fi

# A path the config points at but that is gone is worth shouting about: the
# restore would then come up without the file the panel insists on.
for m in ${MISSING[@]+"${MISSING[@]}"}; do warn "config points at a missing path: $m"; done
echo "==> archiving: ${PATHS[*]}"

# Units only exist for the binary install; a docker host has no unit file.
UNITS=()
for u in "/etc/systemd/system/$PANEL_SVC.service" "/etc/systemd/system/$VKTP_SVC.service"; do
  [ -f "$u" ] && UNITS+=("${u#/}")
done

DOCKER_RUNNING=0
if command -v docker >/dev/null 2>&1; then
  if [ "$(docker inspect -f '{{.State.Running}}' "$PANEL_SVC" 2>/dev/null || true)" = true ]; then
    DOCKER_RUNNING=1
  fi
fi

restore_services() {
  echo "==> restarting services"
  if [ "$DOCKER_RUNNING" = 1 ]; then
    docker start "$PANEL_SVC" >/dev/null 2>&1 || true
  else
    systemctl start "$VKTP_SVC" >/dev/null 2>&1 || true
    systemctl start "$PANEL_SVC" >/dev/null 2>&1 || true
  fi
}
# A failed backup must not leave the panel down, so always resume on the way out.
# It must also not leave a truncated archive that looks like a usable one.
ARCHIVE_OK=0
cleanup() {
  if [ "$ARCHIVE_OK" != 1 ] && [ -f "$OUT" ]; then
    rm -f "$OUT"
    echo "ERROR: backup failed - partial archive removed, nothing to restore from" >&2
  fi
  restore_services
}
trap cleanup EXIT

if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB_PATH" ]; then
  if [ "$(sqlite3 "$DB_PATH" 'PRAGMA integrity_check;' 2>/dev/null || true)" != ok ]; then
    echo "WARNING: sqlite integrity_check did not return ok for $DB_PATH" >&2
  fi
fi

echo "==> stopping services"
systemctl stop "$VKTP_SVC" >/dev/null 2>&1 || true
systemctl stop "$PANEL_SVC" >/dev/null 2>&1 || true
if [ "$DOCKER_RUNNING" = 1 ]; then
  docker stop "$PANEL_SVC" >/dev/null 2>&1 || true
fi

echo "==> writing $OUT"
# No `|| true` here: a silently missing archive is worse than a failed script.
tar -czf "$OUT" -C / "${PATHS[@]}" ${UNITS[@]+"${UNITS[@]}"}
chmod 600 "$OUT"

echo "==> verifying archive"
[ -s "$OUT" ] || { echo "archive is empty" >&2; exit 1; }
LIST=$(tar -tzf "$OUT")
for required in "etc/wings/panel/config.toml" "${DB_PATH#/}"; do
  if ! printf '%s\n' "$LIST" | grep -qx "$required"; then
    echo "ERROR: $required is missing from the archive" >&2
    exit 1
  fi
done

# Record what went in, so the restore can stash exactly these paths before
# overwriting them. Archives made before this sidecar existed fall back to a
# fixed list in wingsv-restore.sh.
printf '%s\n' "${PATHS[@]}" > "$OUT.paths"
chmod 600 "$OUT.paths"

echo "==> ok: $OUT ($(du -h "$OUT" | cut -f1))"
ARCHIVE_OK=1

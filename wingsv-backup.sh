#!/usr/bin/env bash
# wingsv-backup.sh - offline backup of a WINGS panel host.
#
#   sudo bash wingsv-backup.sh [output.tar.gz]
#
# Covers every path install.sh owns: /etc/wings (config, certs, wg key),
# /var/lib/wings (SQLite database), the systemd units and root's acme.sh state.
# Services are stopped first so SQLite and the config are flushed, and they are
# always restarted - even when archiving fails.

set -euo pipefail

PANEL_SVC=wingsv-panel
VKTP_SVC=wings-vktp
SVC_USER=wings
PANEL_CFG=/etc/wings/panel/config.toml
OUT="${1:-/root/wingsv-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$PANEL_CFG" ] || { echo "no $PANEL_CFG - is this a panel host?" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }

# Same parser install.sh uses for its own config keys.
cfg_get() {
  sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p" "$PANEL_CFG" 2>/dev/null | head -1
}

# With --advanced the database may sit outside /var/lib/wings; ask the config
# instead of assuming the default location.
DB_PATH=$(cfg_get DB_PATH)
[ -n "$DB_PATH" ] || DB_PATH=/var/lib/wings/panel/v-wingsnet.db
DB_DIR=$(dirname "$DB_PATH")

# Paths are archived relative to / so tar does not warn about leading slashes
# and the archive extracts with a plain `tar -xzf ... -C /`.
PATHS=(etc/wings var/lib/wings)
add_path() { # add_path <absolute path> - appended as-is, never its parent
  [ -e "$1" ] || return 0
  local rel=${1#/}
  case " ${PATHS[*]} " in *" $rel "*) ;; *) PATHS+=("$rel") ;; esac
}
# Only the database's own directory - not dirname of every extra path: acme.sh
# lives in /root, and archiving /root would swallow the archive being written.
add_path "$DB_DIR"
add_path "$HOME/.acme.sh"

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

echo "==> ok: $OUT ($(du -h "$OUT" | cut -f1))"
ARCHIVE_OK=1

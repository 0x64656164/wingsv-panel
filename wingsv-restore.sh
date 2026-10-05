#!/usr/bin/env bash
# wingsv-restore.sh - restore a wingsv-backup.sh archive onto a panel host.
#
#   sudo bash wingsv-restore.sh /root/wingsv-backup-20260101-120000.tar.gz [--docker|--bin]
#
# Unpacks config + data, then re-runs install.sh. That last step is required:
# the binaries in /usr/local/bin are downloaded by the installer and are not part
# of the backup, so without it the restored units would point at a missing
# ExecStart. install.sh --yes takes the update branch on an existing config, so
# it keeps every setting and needs no manual input.

set -euo pipefail

PANEL_SVC=wingsv-panel
VKTP_SVC=wings-vktp
SVC_USER=wings
# Fetch the installer from the fork these scripts ship with, not from upstream:
# otherwise a restore would re-run an installer whose update path does not match
# this script. Overridable for anyone vendoring the script elsewhere.
INSTALLER_URL="${INSTALLER_URL:-https://raw.githubusercontent.com/0x64656164/wingsv-panel/main/install.sh}"
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

# systemd/binary is the installer's own default, so the restore defaults to it
# too and only touches Docker when explicitly asked.
MODE=bin
ARCHIVE=""
for arg in "$@"; do
  case "$arg" in
    --docker) MODE=docker ;;
    --bin) MODE=bin ;;
    -*) echo "unknown flag: $arg" >&2; exit 1 ;;
    *) ARCHIVE="$arg" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -n "$ARCHIVE" ] || { echo "usage: sudo bash $0 <archive.tar.gz> [--docker|--bin]" >&2; exit 1; }
[ -f "$ARCHIVE" ] || { echo "no such archive: $ARCHIVE" >&2; exit 1; }

# Validate before anything is destroyed: an unreadable or truncated archive must
# abort while the host is still intact.
echo "==> checking archive"
LIST=$(tar -tzf "$ARCHIVE")
printf '%s\n' "$LIST" | grep -qx "etc/wings/panel/config.toml" \
  || { echo "ERROR: archive has no panel config" >&2; exit 1; }
DB_REL=$(printf '%s\n' "$LIST" | grep 'var/lib/wings.*\.db$' | head -1 || true)

# A docker install writes no systemd unit, but never infer docker from that: a
# missing unit must not silently drag a systemd host into a containerised panel.
if [ "$MODE" = bin ] && ! printf '%s\n' "$LIST" | grep -qx "etc/systemd/system/$PANEL_SVC.service"; then
  echo "note: archive has no $PANEL_SVC.service unit, installing as a systemd service anyway"
fi
echo "==> mode: $MODE${DB_REL:+ (database: $DB_REL)}"

echo "==> stopping services"
systemctl stop "$VKTP_SVC" >/dev/null 2>&1 || true
systemctl stop "$PANEL_SVC" >/dev/null 2>&1 || true
if command -v docker >/dev/null 2>&1; then
  docker rm -f "$PANEL_SVC" >/dev/null 2>&1 || true
fi

# Keep the previous state instead of deleting it, so a bad archive can be undone
# by unpacking it back over these directories.
STASH="/root/wingsv-pre-restore-$(date +%Y%m%d-%H%M%S)"
echo "==> moving current state to $STASH"
for d in etc/wings var/lib/wings root/.acme.sh; do
  if [ -e "/$d" ]; then
    mkdir -p "$STASH/$(dirname "$d")"
    mv "/$d" "$STASH/$d"
  fi
done
mkdir -p "$STASH/etc/systemd/system"
for u in "$PANEL_SVC" "$VKTP_SVC"; do
  if [ -f "/etc/systemd/system/$u.service" ]; then
    mv "/etc/systemd/system/$u.service" "$STASH/etc/systemd/system/"
  fi
done

echo "==> extracting"
tar -xzf "$ARCHIVE" -C /

if id "$SVC_USER" >/dev/null 2>&1; then
  echo "==> user $SVC_USER exists"
else
  echo "==> creating user $SVC_USER"
  useradd --system --home /var/lib/wings --shell /usr/sbin/nologin "$SVC_USER"
fi

# The installer does the same, but doing it here keeps ownership correct even if
# the download fails.
chown -R "$SVC_USER":"$SVC_USER" /etc/wings /var/lib/wings 2>/dev/null || true
if [ -f /etc/wings/panel/config.toml ]; then
  chmod 600 /etc/wings/panel/config.toml
fi

INSTALLER="$SCRIPT_DIR/install.sh"
if [ ! -f "$INSTALLER" ]; then
  INSTALLER=/root/install.sh
  command -v curl >/dev/null 2>&1 || { echo "curl is required to fetch install.sh" >&2; exit 1; }
  curl -fsSL "$INSTALLER_URL" -o "$INSTALLER"
fi

echo "==> re-running the installer to restore binaries and services"
if [ "$MODE" = docker ]; then
  bash "$INSTALLER" --yes --docker
else
  bash "$INSTALLER" --yes
fi

systemctl enable "$VKTP_SVC" >/dev/null 2>&1 || true
if [ "$MODE" = bin ]; then
  systemctl enable "$PANEL_SVC" >/dev/null 2>&1 || true
fi

echo "==> status"
if [ "$MODE" = docker ]; then
  docker ps --filter "name=$PANEL_SVC" --format 'container {{.Names}}: {{.Status}}' || true
else
  echo "panel: $(systemctl is-active "$PANEL_SVC" || true)"
fi
echo "vktp:   $(systemctl is-active "$VKTP_SVC" || true)"
if [ -n "$DB_REL" ]; then ls -l "/$DB_REL" || true; fi
grep -m1 PUBLIC_BASE_URL /etc/wings/panel/config.toml || true
echo "previous state kept in $STASH"

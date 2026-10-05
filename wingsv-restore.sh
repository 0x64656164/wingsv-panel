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
# by unpacking it back over these directories. The list comes from the backup's
# sidecar manifest, which records the paths discovery actually archived.
#
# "shared" entries are acme.sh state that every other service on this host also
# writes to (the CA account, account.conf, acme.sh.env). If anything touched them
# between the backup and now, rolling them back would undo that - and would pull
# the rug out from under a sibling service. So a live copy always wins there, and
# the archived one stays in $STASH to be merged by hand if it is really wanted.
OWNED=(); SHARED=()
if [ -f "$ARCHIVE.paths" ]; then
  while IFS=$'\t' read -r kind p; do
    case "$p" in /*|""|"."|"..") continue;; esac
    case "$kind" in
      shared) SHARED+=("$p");;
      *)      OWNED+=("$p");;
    esac
  done < "$ARCHIVE.paths"
else
  # Archive predates the manifest: assume the acme.sh tree is shared, since that
  # is the dangerous direction to get wrong.
  OWNED=(etc/wings var/lib/wings)
  SHARED=(root/.acme.sh)
fi
STASH_DIRS=("${OWNED[@]}" ${SHARED[@]+"${SHARED[@]}"})

STASH="/root/wingsv-pre-restore-$(date +%Y%m%d-%H%M%S)"
echo "==> moving current state to $STASH"
for d in "${STASH_DIRS[@]}"; do
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

# acme.sh state is shared with every other service on this host, so the archived
# copy must not replace it wholesale: that would roll back a sibling service's
# registration or a newer Le_Webroot. Instead the live copy stays the base and
# only what it is missing gets filled in from the archive.
merge_key_file() { # merge_key_file <archived> <live>
  local a=$1 l=$2 line k
  [ -f "$a" ] || return 0
  if [ ! -f "$l" ]; then
    cp -p "$a" "$l"; echo "    + ${l##*/} was missing, took the archived one"; return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue;; esac
    k=${line%%=*}
    k=${k//[[:space:]]/}
    [ -n "$k" ] || continue
    # Only keys the live file never defines. A key it does define keeps its live
    # value: acme.sh lets the last assignment win, so appending the archived
    # line would quietly roll the setting back - the very thing to avoid.
    if ! grep -q "^[[:space:]]*$k[[:space:]]*=" "$l"; then
      printf '%s\n' "$line" >> "$l"
      echo "    + $k restored into ${l##*/}"
    fi
  done < "$a"
}
merge_tree() { # merge_tree <archived dir> <live dir>
  local a=$1 l=$2 f
  [ -d "$a" ] || return 0
  if [ ! -d "$l" ]; then
    mkdir -p "$(dirname "$l")"; cp -a "$a" "$l"
    echo "    + ${l##*/} was missing, took the archived one"; return 0
  fi
  while IFS= read -r f; do
    # Presence only: a file that exists live is never overwritten.
    [ -e "$l/$f" ] && continue
    mkdir -p "$(dirname "$l/$f")"
    cp -p "$a/$f" "$l/$f"
    echo "    + ${f#./} restored into ${l##*/}"
  done < <(cd "$a" && find . -type f)
}
if [ -d "$STASH" ]; then
  for d in ${SHARED[@]+"${SHARED[@]}"}; do
    # Nothing was on the host before: the freshly extracted copy already stands.
    [ -e "$STASH/$d" ] || continue
    echo "==> merging shared $d"
    if [ -d "/$d" ]; then merge_tree "/$d" "$STASH/$d"; else merge_key_file "/$d" "$STASH/$d"; fi
    rm -rf "/$d"
    mkdir -p "$(dirname "/$d")"
    mv "$STASH/$d" "/$d"
  done
fi

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

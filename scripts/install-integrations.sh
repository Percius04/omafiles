#!/bin/bash
# Opt-in user defaults for OmaFiles desktop and portal integration.
set -euo pipefail

APP_ID=io.github.percius04.omafiles
ACTION=${1:-}
case "$ACTION" in
  --enable|--disable|--status) ;;
  *) printf 'Usage: %s --enable|--disable|--status\n' "${0##*/}" >&2; exit 2 ;;
esac

SELF_RES=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL_DATA_ROOT=$(dirname "$SELF_RES")
XDG_DATA=${XDG_DATA_HOME:-$HOME/.local/share}
XDG_CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/omafiles/integrations
TRANSACTION_DIR=$STATE_DIR/transaction
STATIC_SOURCE=$SELF_RES/integrations
SHARED_SERVICE_SOURCE=$STATIC_SOURCE/org.freedesktop.FileManager1.service
SHARED_SERVICE_TARGET=$XDG_DATA/dbus-1/services/org.freedesktop.FileManager1.service
MIMEAPPS_PATH=$XDG_CONFIG/mimeapps.list
PORTAL_CONFIG_DIR=$XDG_CONFIG/xdg-desktop-portal
PORTAL_PATHS=(
  "$PORTAL_CONFIG_DIR/hyprland-portals.conf"
  "$PORTAL_CONFIG_DIR/portals.conf"
)
PORTAL_DEFAULTS=(
  $'[preferred]\ndefault=hyprland;gtk\n'
  $'[preferred]\ndefault=gtk\n'
)
# These descriptors have package-unique names and may be installed statically.
# FileManager1 is shared with Nautilus, so enable manages only its user copy.
STATIC_NAMES=(
  io.github.percius04.omafiles.desktop
  io.github.percius04.omafiles.service
  org.freedesktop.impl.portal.desktop.omafiles.service
  omafiles.portal
)
STATIC_TARGETS=(
  "$INSTALL_DATA_ROOT/applications/io.github.percius04.omafiles.desktop"
  "$INSTALL_DATA_ROOT/dbus-1/services/io.github.percius04.omafiles.service"
  "$INSTALL_DATA_ROOT/dbus-1/services/org.freedesktop.impl.portal.desktop.omafiles.service"
  "$INSTALL_DATA_ROOT/xdg-desktop-portal/portals/omafiles.portal"
)

hash_file() { sha256sum -- "$1" | awk '{print $1}'; }
current_file_hash() {
  if [[ -L $1 || -e $1 && ! -f $1 ]]; then
    printf 'non-regular\n'
  elif [[ -f $1 ]]; then
    hash_file "$1"
  else
    printf 'missing\n'
  fi
}
atomic_text() {
  local target=$1 value=$2 tmp
  mkdir -p -- "$(dirname "$target")"
  tmp=$(mktemp "${target}.tmp.XXXXXX")
  printf '%s' "$value" >"$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$target"
}
atomic_copy() {
  local source=$1 target=$2 tmp
  mkdir -p -- "$(dirname "$target")"
  tmp=$(mktemp "${target}.tmp.XXXXXX")
  cp -- "$source" "$tmp"
  chmod --reference="$source" "$tmp"
  mv -f -- "$tmp" "$target"
}
record_completed_step() {
  local step=$1 managed_hash=$2
  atomic_text "$TRANSACTION_DIR/$step.completed-hash" "$managed_hash"
  if [[ ${OMAFILES_TEST_INTERRUPT_AFTER:-} == "$step" ]]; then
    printf 'OmaFiles integration test interruption after %s.\n' "$step" >&2
    exit 86
  fi
}
step_was_managed() {
  [[ -f $STATE_DIR/enabled || -f $TRANSACTION_DIR/$1.completed-hash ]]
}
managed_step_hash() {
  local step=$1 persistent=$2 completed
  completed=$TRANSACTION_DIR/$step.completed-hash
  if [[ -f $STATE_DIR/enabling && -f $completed ]]; then
    cat "$completed"
  elif [[ -f $persistent ]]; then
    cat "$persistent"
  else
    printf 'unknown\n'
  fi
}

static_status=0
check_or_repair_static() {
  local repair=$1 i source target source_hash target_hash manifest=""
  for ((i=0; i<${#STATIC_NAMES[@]}; i++)); do
    source=$STATIC_SOURCE/${STATIC_NAMES[$i]}
    target=${STATIC_TARGETS[$i]}
    if [[ ! -f $source ]]; then
      printf 'OmaFiles integration source is missing: %s\n' "$source" >&2
      static_status=1
      continue
    fi
    source_hash=$(hash_file "$source")
    if [[ ! -f $target ]]; then
      if [[ $repair == 1 && $SELF_RES == "$XDG_DATA/omafiles" ]]; then
        atomic_copy "$source" "$target"
        printf 'Repaired static integration file: %s\n' "$target"
      else
        printf 'OmaFiles static integration is missing; reinstall the package: %s\n' "$target" >&2
        static_status=1
        continue
      fi
    fi
    target_hash=$(hash_file "$target")
    if [[ $target_hash != "$source_hash" ]]; then
      printf 'Preserving modified static integration file: %s\n' "$target" >&2
      static_status=1
    fi
    manifest+="${source_hash}"$'\t'"${target_hash}"$'\t'"${target}"$'\n'
  done
  [[ $repair == 0 ]] || atomic_text "$STATE_DIR/static-manifest.tsv" "$manifest"
}

capture_file_baseline() {
  local key=$1 path=$2 base
  base=$STATE_DIR/baseline/$key
  atomic_text "$base.path" "$path"
  if [[ -L $path || -e $path && ! -f $path ]]; then
    printf 'Refusing non-regular integration file: %s\n' "$path" >&2
    exit 1
  fi
  if [[ -f $path ]]; then
    atomic_text "$base.existed" 1
    atomic_copy "$path" "$base.before"
    atomic_text "$base.before-hash" "$(hash_file "$path")"
  else
    atomic_text "$base.existed" 0
    atomic_text "$base.before-hash" missing
  fi
}

file_matches_baseline() {
  local key=$1 path=$2 base
  base=$STATE_DIR/baseline/$key
  if [[ $(cat "$base.existed") == 1 ]]; then
    [[ -f $path && $(hash_file "$path") == "$(cat "$base.before-hash")" ]]
  else
    [[ ! -e $path && ! -L $path ]]
  fi
}

restore_file_baseline() {
  local key=$1 path=$2 base
  base=$STATE_DIR/baseline/$key
  if [[ $(cat "$base.existed") == 1 ]]; then
    atomic_copy "$base.before" "$path"
  else
    rm -f -- "$path"
  fi
}

capture_baseline() {
  [[ -f $STATE_DIR/baseline-captured ]] && return
  mkdir -p "$STATE_DIR/baseline"
  local prior_mime i
  prior_mime=$(xdg-mime query default inode/directory 2>/dev/null || true)
  atomic_text "$STATE_DIR/baseline/mime-handler" "$prior_mime"
  capture_file_baseline mimeapps "$MIMEAPPS_PATH"
  capture_file_baseline shared-service "$SHARED_SERVICE_TARGET"
  for ((i=0; i<${#PORTAL_PATHS[@]}; i++)); do
    capture_file_baseline "portal-$i" "${PORTAL_PATHS[$i]}"
  done
  atomic_text "$STATE_DIR/baseline-captured" 1
}

write_managed_portal() {
  local path=$1 default_content=$2
  mkdir -p -- "$(dirname "$path")"
  python3 - "$path" "$default_content" <<'PY'
import os
import stat
import sys
import tempfile

path, default_content = sys.argv[1:]
if os.path.exists(path):
    with open(path, "r", encoding="utf-8", newline="") as stream:
        text = stream.read()
    mode = stat.S_IMODE(os.stat(path).st_mode)
else:
    text = default_content
    mode = 0o600

lines = text.splitlines(keepends=True)
newline = "\r\n" if "\r\n" in text else "\n"
preferred = None
section_end = len(lines)
for index, line in enumerate(lines):
    stripped = line.strip()
    if stripped.lower() == "[preferred]":
        preferred = index
        continue
    if preferred is not None and index > preferred and stripped.startswith("[") and stripped.endswith("]"):
        section_end = index
        break

key = "org.freedesktop.impl.portal.FileChooser=omafiles" + newline
if preferred is None:
    if lines and not lines[-1].endswith(("\n", "\r")):
        lines[-1] += newline
    if lines and lines[-1].strip():
        lines.append(newline)
    lines.extend(["[preferred]" + newline, key])
else:
    matches = []
    for index in range(preferred + 1, section_end):
        if lines[index].split("=", 1)[0].strip() == "org.freedesktop.impl.portal.FileChooser":
            matches.append(index)
    if matches:
        lines[matches[0]] = key
        for index in reversed(matches[1:]):
            del lines[index]
    else:
        lines.insert(preferred + 1, key)

fd, temporary = tempfile.mkstemp(prefix=".omafiles-portals-", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
        stream.write("".join(lines))
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, mode)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

reload_desktop_services() {
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$INSTALL_DATA_ROOT/applications" >/dev/null 2>&1 || true
  command -v dbus-send >/dev/null 2>&1 \
    && dbus-send --session --type=method_call --dest=org.freedesktop.DBus \
      /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1 || true
}
restart_portal() {
  command -v systemctl >/dev/null 2>&1 \
    && systemctl --user try-restart xdg-desktop-portal >/dev/null 2>&1 || true
}

shared_changed=0
manage_shared_service() {
  local managed_hash=$STATE_DIR/shared-service.managed-hash
  shared_changed=0
  if [[ -f $STATE_DIR/enabled && -f $managed_hash ]]; then
    if [[ $(current_file_hash "$SHARED_SERVICE_TARGET") == "$(cat "$managed_hash")" ]]; then
      return 0
    fi
    printf 'Preserving user-edited shared D-Bus service: %s\n' "$SHARED_SERVICE_TARGET" >&2
    return 1
  fi
  if ! file_matches_baseline shared-service "$SHARED_SERVICE_TARGET"; then
    printf 'Preserving shared D-Bus service changed since baseline: %s\n' "$SHARED_SERVICE_TARGET" >&2
    return 1
  fi
  atomic_copy "$SHARED_SERVICE_SOURCE" "$SHARED_SERVICE_TARGET"
  atomic_text "$managed_hash" "$(hash_file "$SHARED_SERVICE_TARGET")"
  shared_changed=1
}

enable_integration() {
  command -v xdg-mime >/dev/null 2>&1 || { echo 'OmaFiles integration requires xdg-mime.' >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo 'OmaFiles integration requires python3.' >&2; exit 1; }
  mkdir -p "$STATE_DIR"
  capture_baseline

  # This marker is durable before the first integration mutation. Each completed
  # user-default mutation then records the exact bytes it owns in transaction/.
  if [[ ! -f $STATE_DIR/enabling ]]; then
    rm -rf -- "$TRANSACTION_DIR"
    atomic_text "$STATE_DIR/enabling" 1
  fi
  check_or_repair_static 1
  [[ $static_status == 0 && -f $SHARED_SERVICE_SOURCE ]] || exit 1

  local changed=0 incomplete=0 current prior i path managed_hash hash
  current=$(xdg-mime query default inode/directory 2>/dev/null || true)
  prior=$(cat "$STATE_DIR/baseline/mime-handler")
  if [[ $current == "$APP_ID.desktop" ]]; then
    atomic_text "$STATE_DIR/mimeapps.managed-hash" "$(current_file_hash "$MIMEAPPS_PATH")"
  elif [[ ! -f $STATE_DIR/enabled && $current == "$prior" ]]; then
    xdg-mime default "$APP_ID.desktop" inode/directory
    hash=$(current_file_hash "$MIMEAPPS_PATH")
    atomic_text "$STATE_DIR/mimeapps.managed-hash" "$hash"
    record_completed_step mime "$hash"
    changed=1
  else
    printf 'Preserving user MIME choice: %s\n' "${current:-<none>}" >&2
    incomplete=1
  fi

  for ((i=0; i<${#PORTAL_PATHS[@]}; i++)); do
    path=${PORTAL_PATHS[$i]}
    managed_hash=$STATE_DIR/portal-$i.managed-hash
    if [[ -f $STATE_DIR/enabled && -f $managed_hash ]]; then
      if [[ $(current_file_hash "$path") == "$(cat "$managed_hash")" ]]; then
        continue
      fi
      printf 'Preserving user-edited portal config: %s\n' "$path" >&2
      incomplete=1
      continue
    fi
    if ! file_matches_baseline "portal-$i" "$path"; then
      printf 'Preserving portal config changed since baseline: %s\n' "$path" >&2
      incomplete=1
      continue
    fi
    write_managed_portal "$path" "${PORTAL_DEFAULTS[$i]}"
    hash=$(hash_file "$path")
    atomic_text "$managed_hash" "$hash"
    record_completed_step "portal-$i" "$hash"
    changed=1
  done
  if manage_shared_service; then
    if (( shared_changed != 0 )); then
      hash=$(cat "$STATE_DIR/shared-service.managed-hash")
      record_completed_step shared-service "$hash"
    fi
    changed=$((changed + shared_changed))
  else
    incomplete=1
  fi

  reload_desktop_services
  (( changed == 0 )) || restart_portal
  if (( incomplete != 0 )); then
    printf 'OmaFiles user integration enable is incomplete.\n' >&2
    return 1
  fi
  atomic_text "$STATE_DIR/enabled" 1
  rm -f -- "$STATE_DIR/enabling"
  rm -rf -- "$TRANSACTION_DIR"
  printf 'OmaFiles user integration enabled.\n'
}

disable_integration() {
  command -v xdg-mime >/dev/null 2>&1 || { echo 'OmaFiles integration requires xdg-mime.' >&2; exit 1; }
  if [[ ! -f $STATE_DIR/enabled && ! -f $STATE_DIR/enabling ]]; then
    printf 'OmaFiles user integration is already disabled.\n'
    return
  fi
  local changed=0 incomplete=0 current i path managed_hash expected_hash
  current=$(xdg-mime query default inode/directory 2>/dev/null || true)
  managed_hash=$STATE_DIR/mimeapps.managed-hash
  if step_was_managed mime; then
    expected_hash=$(managed_step_hash mime "$managed_hash")
    if file_matches_baseline mimeapps "$MIMEAPPS_PATH"; then
      :
    elif [[ $(current_file_hash "$MIMEAPPS_PATH") == "$expected_hash" ]]; then
      restore_file_baseline mimeapps "$MIMEAPPS_PATH"
      changed=1
    else
      printf 'Preserving user-edited MIME configuration: %s (%s)\n' \
        "$MIMEAPPS_PATH" "${current:-<none>}" >&2
      incomplete=1
    fi
  fi

  for ((i=0; i<${#PORTAL_PATHS[@]}; i++)); do
    step_was_managed "portal-$i" || continue
    path=${PORTAL_PATHS[$i]}
    managed_hash=$STATE_DIR/portal-$i.managed-hash
    expected_hash=$(managed_step_hash "portal-$i" "$managed_hash")
    if file_matches_baseline "portal-$i" "$path"; then
      continue
    fi
    if [[ $(current_file_hash "$path") == "$expected_hash" ]]; then
      restore_file_baseline "portal-$i" "$path"
      changed=1
    else
      printf 'Preserving user-edited portal config: %s\n' "$path" >&2
      incomplete=1
    fi
  done

  if step_was_managed shared-service; then
    managed_hash=$STATE_DIR/shared-service.managed-hash
    expected_hash=$(managed_step_hash shared-service "$managed_hash")
    if file_matches_baseline shared-service "$SHARED_SERVICE_TARGET"; then
      :
    elif [[ $(current_file_hash "$SHARED_SERVICE_TARGET") == "$expected_hash" ]]; then
      restore_file_baseline shared-service "$SHARED_SERVICE_TARGET"
      changed=1
    else
      printf 'Preserving user-edited shared D-Bus service: %s\n' "$SHARED_SERVICE_TARGET" >&2
      incomplete=1
    fi
  fi

  reload_desktop_services
  (( changed == 0 )) || restart_portal
  if (( incomplete != 0 )); then
    printf 'OmaFiles user integration disable is incomplete; integration state retained.\n' >&2
    return 1
  fi
  rm -f -- "$STATE_DIR/enabled" "$STATE_DIR/enabling"
  rm -rf -- "$TRANSACTION_DIR"
  printf 'OmaFiles user integration disabled.\n'
}

status_integration() {
  check_or_repair_static 0
  local ok=$((static_status == 0 ? 1 : 0)) current i path hash
  [[ -f $STATE_DIR/enabled ]] || ok=0
  if ! command -v xdg-mime >/dev/null 2>&1; then
    printf 'MIME default: unavailable (xdg-mime not found)\n'
    ok=0
  else
    current=$(xdg-mime query default inode/directory 2>/dev/null || true)
    printf 'MIME default: %s\n' "${current:-<none>}"
    [[ $current == "$APP_ID.desktop" ]] || ok=0
  fi
  for ((i=0; i<${#PORTAL_PATHS[@]}; i++)); do
    path=${PORTAL_PATHS[$i]}
    hash=$STATE_DIR/portal-$i.managed-hash
    if [[ -f $hash && $(current_file_hash "$path") == "$(cat "$hash")" ]]; then
      printf 'Portal config managed: %s\n' "$path"
    else
      printf 'Portal config not managed: %s\n' "$path"
      ok=0
    fi
  done
  hash=$STATE_DIR/shared-service.managed-hash
  if [[ -f $hash && $(current_file_hash "$SHARED_SERVICE_TARGET") == "$(cat "$hash")" ]]; then
    printf 'Shared FileManager1 service managed: %s\n' "$SHARED_SERVICE_TARGET"
  else
    printf 'Shared FileManager1 service not managed: %s\n' "$SHARED_SERVICE_TARGET"
    ok=0
  fi
  if (( ok == 1 )); then
    printf 'OmaFiles user integration: enabled\n'
    return 0
  fi
  printf 'OmaFiles user integration: disabled or modified\n'
  return 1
}

case "$ACTION" in
  --enable) enable_integration ;;
  --disable) disable_integration ;;
  --status) status_integration ;;
esac

#!/bin/bash
# Isolated integration lifecycle tests. Never touches the live profile.
set -euo pipefail

SCRIPT=${1:?usage: test-integrations.sh /path/to/install-integrations.sh}
TOP=$(mktemp -d)
trap 'rm -rf "$TOP"' EXIT

make_case() {
  local root=$1
  export HOME="$root/home"
  export XDG_DATA_HOME="$HOME/.local/share"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_STATE_HOME="$HOME/.local/state"
  export XDG_RUNTIME_DIR="$root/runtime"
  export TEST_ROOT="$root"
  mkdir -p "$XDG_DATA_HOME/omafiles/scripts" "$XDG_DATA_HOME/omafiles/integrations" \
    "$XDG_CONFIG_HOME/xdg-desktop-portal" "$XDG_RUNTIME_DIR" "$root/bin"
  cp "$SCRIPT" "$XDG_DATA_HOME/omafiles/scripts/install-integrations.sh"
  chmod +x "$XDG_DATA_HOME/omafiles/scripts/install-integrations.sh"

  cat >"$XDG_DATA_HOME/omafiles/integrations/io.github.percius04.omafiles.desktop" <<EOF
[Desktop Entry]
Exec=$XDG_DATA_HOME/omafiles/scripts/open-path.sh %u
EOF
  cat >"$XDG_DATA_HOME/omafiles/integrations/io.github.percius04.omafiles.service" <<EOF
[D-BUS Service]
Exec=$XDG_DATA_HOME/omafiles/scripts/dbus-app-open.py
EOF
  cat >"$XDG_DATA_HOME/omafiles/integrations/org.freedesktop.FileManager1.service" <<EOF
[D-BUS Service]
Name=org.freedesktop.FileManager1
Exec=$XDG_DATA_HOME/omafiles/scripts/dbus-filemanager1.py
EOF
  cat >"$XDG_DATA_HOME/omafiles/integrations/org.freedesktop.impl.portal.desktop.omafiles.service" <<EOF
[D-BUS Service]
Exec=$XDG_DATA_HOME/omafiles/scripts/dbus-filechooser.py
EOF
  cat >"$XDG_DATA_HOME/omafiles/integrations/omafiles.portal" <<'EOF'
[portal]
DBusName=org.freedesktop.impl.portal.desktop.omafiles
Interfaces=org.freedesktop.impl.portal.FileChooser;
UseIn=Hyprland;
EOF
  for helper in open-path.sh dbus-app-open.py dbus-filemanager1.py dbus-filechooser.py; do
    printf '#!/bin/sh\nexit 0\n' >"$XDG_DATA_HOME/omafiles/scripts/$helper"
    chmod +x "$XDG_DATA_HOME/omafiles/scripts/$helper"
  done

  cat >"$root/bin/xdg-mime" <<'EOF'
#!/bin/bash
set -euo pipefail
file=$XDG_CONFIG_HOME/mimeapps.list
if [[ $1 == query ]]; then
  [[ -f $file ]] || exit 0
  sed -n 's/^inode\/directory=//p' "$file" | tail -n 1 | sed 's/;.*//'
  exit 0
fi
handler=$2
mkdir -p "$(dirname "$file")"
python3 - "$file" "$handler" <<'PY'
import os
import sys
path, handler = sys.argv[1:]
text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
lines = [line for line in text.splitlines() if not line.startswith("inode/directory=")]
if "[Default Applications]" not in lines:
    lines.extend(([""] if lines and lines[-1] else []) + ["[Default Applications]"])
lines.append(f"inode/directory={handler};")
with open(path, "w", encoding="utf-8") as stream:
    stream.write("\n".join(lines) + "\n")
PY
EOF
  cat >"$root/bin/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_ROOT/systemctl.log"
EOF
  for command_name in update-desktop-database dbus-send; do
    printf '#!/bin/sh\nexit 0\n' >"$root/bin/$command_name"
  done
  chmod +x "$root/bin"/*
  export PATH="$root/bin:/usr/bin:/bin"
}

# Existing MIME, portal, and shared FileManager1 descriptors round-trip exactly.
ROOT1=$TOP/existing
make_case "$ROOT1"
printf '[Default Applications]\ninode/directory=old.desktop;\n' >"$XDG_CONFIG_HOME/mimeapps.list"
printf '[preferred]\ndefault=hyprland;gtk\ncustom=value\n' >"$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf"
mkdir -p "$XDG_DATA_HOME/dbus-1/services"
printf '[D-BUS Service]\nName=org.freedesktop.FileManager1\nExec=/usr/bin/nautilus --gapplication-service\n' \
  >"$XDG_DATA_HOME/dbus-1/services/org.freedesktop.FileManager1.service"
cp "$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf" "$ROOT1/hyprland.before"
cp "$XDG_DATA_HOME/dbus-1/services/org.freedesktop.FileManager1.service" "$ROOT1/shared.before"
INTEGRATE=$XDG_DATA_HOME/omafiles/scripts/install-integrations.sh
"$INTEGRATE" --enable
[[ $(xdg-mime query default inode/directory) == io.github.percius04.omafiles.desktop ]]
grep -q 'dbus-filemanager1.py' "$XDG_DATA_HOME/dbus-1/services/org.freedesktop.FileManager1.service"
grep -q '^org.freedesktop.impl.portal.FileChooser=omafiles$' \
  "$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf"

# Idempotence and repair apply only to package-unique static descriptors.
managed_hash=$(sha256sum "$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf")
rm "$XDG_DATA_HOME/dbus-1/services/io.github.percius04.omafiles.service"
"$INTEGRATE" --enable
[[ $managed_hash == "$(sha256sum "$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf")" ]]
[[ -f "$XDG_DATA_HOME/dbus-1/services/io.github.percius04.omafiles.service" ]]
"$INTEGRATE" --status
"$INTEGRATE" --disable
[[ $(xdg-mime query default inode/directory) == old.desktop ]]
cmp "$ROOT1/hyprland.before" "$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf"
cmp "$ROOT1/shared.before" "$XDG_DATA_HOME/dbus-1/services/org.freedesktop.FileManager1.service"
[[ ! -e "$XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf" ]]

# A portal edit survives disable, which stays incomplete and retains enabled state.
"$INTEGRATE" --enable
printf '\nuser-edit=yes\n' >>"$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf"
if "$INTEGRATE" --disable >"$ROOT1/disable-edited-portal.out" 2>&1; then
  echo 'disable unexpectedly accepted edited portal config' >&2
  exit 1
fi
grep -q '^user-edit=yes$' "$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf"
grep -q 'disable is incomplete' "$ROOT1/disable-edited-portal.out"
[[ -f "$XDG_STATE_HOME/omafiles/integrations/enabled" ]]

# An empty prior MIME query restores the exact prior mimeapps.list bytes.
ROOT2=$TOP/empty
make_case "$ROOT2"
printf '[Added Associations]\ntext/plain=editor.desktop;\n' >"$XDG_CONFIG_HOME/mimeapps.list"
cp "$XDG_CONFIG_HOME/mimeapps.list" "$ROOT2/mimeapps.before"
INTEGRATE=$XDG_DATA_HOME/omafiles/scripts/install-integrations.sh
"$INTEGRATE" --enable
[[ $(xdg-mime query default inode/directory) == io.github.percius04.omafiles.desktop ]]
[[ -f "$XDG_DATA_HOME/dbus-1/services/org.freedesktop.FileManager1.service" ]]
"$INTEGRATE" --disable
cmp "$ROOT2/mimeapps.before" "$XDG_CONFIG_HOME/mimeapps.list"
[[ -z $(xdg-mime query default inode/directory) ]]
[[ ! -e "$XDG_DATA_HOME/dbus-1/services/org.freedesktop.FileManager1.service" ]]

# MIME and shared-service edits after enable both survive an incomplete disable.
"$INTEGRATE" --enable
printf 'user-mime-edit=yes\n' >>"$XDG_CONFIG_HOME/mimeapps.list"
printf 'user-service-edit=yes\n' >>"$XDG_DATA_HOME/dbus-1/services/org.freedesktop.FileManager1.service"
if "$INTEGRATE" --disable >"$ROOT2/disable-edited-user-files.out" 2>&1; then
  echo 'disable unexpectedly accepted edited MIME/shared service' >&2
  exit 1
fi
grep -q '^user-mime-edit=yes$' "$XDG_CONFIG_HOME/mimeapps.list"
grep -q '^user-service-edit=yes$' "$XDG_DATA_HOME/dbus-1/services/org.freedesktop.FileManager1.service"
grep -q 'MIME configuration' "$ROOT2/disable-edited-user-files.out"
grep -q 'shared D-Bus service' "$ROOT2/disable-edited-user-files.out"
[[ -f "$XDG_STATE_HOME/omafiles/integrations/enabled" ]]

# A MIME edit also survives when the saved prior handler was nonempty.
ROOT3=$TOP/nonempty-edited
make_case "$ROOT3"
printf '[Default Applications]\ninode/directory=old.desktop;\n' >"$XDG_CONFIG_HOME/mimeapps.list"
INTEGRATE=$XDG_DATA_HOME/omafiles/scripts/install-integrations.sh
"$INTEGRATE" --enable
printf 'user-mime-edit=yes\n' >>"$XDG_CONFIG_HOME/mimeapps.list"
if "$INTEGRATE" --disable >"$ROOT3/disable-edited-mime.out" 2>&1; then
  echo 'disable unexpectedly accepted edited MIME with a nonempty baseline' >&2
  exit 1
fi
grep -q '^user-mime-edit=yes$' "$XDG_CONFIG_HOME/mimeapps.list"
[[ $(xdg-mime query default inode/directory) == io.github.percius04.omafiles.desktop ]]
grep -q 'MIME configuration' "$ROOT3/disable-edited-mime.out"
[[ -f "$XDG_STATE_HOME/omafiles/integrations/enabled" ]]

# Every managed mutation has an isolated interruption seam. Disable must recover
# only recorded completed steps, restore exact bytes, and clear transaction state.
for interrupt_step in mime portal-0 portal-1 shared-service; do
  INTERRUPT_ROOT="$TOP/interrupted-$interrupt_step"
  make_case "$INTERRUPT_ROOT"
  printf '[Default Applications]\ninode/directory=old.desktop;\ncustom=mime\n' \
    >"$XDG_CONFIG_HOME/mimeapps.list"
  printf '[preferred]\ndefault=hyprland;gtk\ncustom=hyprland\n' \
    >"$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf"
  printf '[preferred]\ndefault=gtk\ncustom=generic\n' \
    >"$XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf"
  mkdir -p "$XDG_DATA_HOME/dbus-1/services"
  printf '[D-BUS Service]\nName=org.freedesktop.FileManager1\nExec=/baseline/file-manager\n' \
    >"$XDG_DATA_HOME/dbus-1/services/org.freedesktop.FileManager1.service"
  cp "$XDG_CONFIG_HOME/mimeapps.list" "$INTERRUPT_ROOT/mime.before"
  cp "$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf" \
    "$INTERRUPT_ROOT/portal-0.before"
  cp "$XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf" \
    "$INTERRUPT_ROOT/portal-1.before"
  cp "$XDG_DATA_HOME/dbus-1/services/org.freedesktop.FileManager1.service" \
    "$INTERRUPT_ROOT/shared.before"
  INTEGRATE=$XDG_DATA_HOME/omafiles/scripts/install-integrations.sh
  if OMAFILES_TEST_INTERRUPT_AFTER="$interrupt_step" "$INTEGRATE" --enable \
      >"$INTERRUPT_ROOT/enable.out" 2>&1; then
    echo "enable did not interrupt after $interrupt_step" >&2
    exit 1
  fi
  [[ -f "$XDG_STATE_HOME/omafiles/integrations/enabling" ]]
  [[ ! -e "$XDG_STATE_HOME/omafiles/integrations/enabled" ]]
  "$INTEGRATE" --disable
  cmp "$INTERRUPT_ROOT/mime.before" "$XDG_CONFIG_HOME/mimeapps.list"
  cmp "$INTERRUPT_ROOT/portal-0.before" \
    "$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf"
  cmp "$INTERRUPT_ROOT/portal-1.before" \
    "$XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf"
  cmp "$INTERRUPT_ROOT/shared.before" \
    "$XDG_DATA_HOME/dbus-1/services/org.freedesktop.FileManager1.service"
  [[ ! -e "$XDG_STATE_HOME/omafiles/integrations/enabling" ]]
  [[ ! -e "$XDG_STATE_HOME/omafiles/integrations/enabled" ]]
  [[ ! -e "$XDG_STATE_HOME/omafiles/integrations/transaction" ]]
done

# An edit after an interrupted completed step is never overwritten. Disable
# reports the recovery as incomplete and retains the enabling transaction.
EDITED_INTERRUPT_ROOT="$TOP/interrupted-edited-mime"
make_case "$EDITED_INTERRUPT_ROOT"
printf '[Default Applications]\ninode/directory=old.desktop;\n' \
  >"$XDG_CONFIG_HOME/mimeapps.list"
INTEGRATE=$XDG_DATA_HOME/omafiles/scripts/install-integrations.sh
if OMAFILES_TEST_INTERRUPT_AFTER=mime "$INTEGRATE" --enable \
    >"$EDITED_INTERRUPT_ROOT/enable.out" 2>&1; then
  echo 'enable did not interrupt before edited recovery case' >&2
  exit 1
fi
printf 'user-after-interruption=yes\n' >>"$XDG_CONFIG_HOME/mimeapps.list"
if "$INTEGRATE" --disable >"$EDITED_INTERRUPT_ROOT/disable.out" 2>&1; then
  echo 'disable overwrote a user edit after interrupted enable' >&2
  exit 1
fi
grep -q '^user-after-interruption=yes$' "$XDG_CONFIG_HOME/mimeapps.list"
grep -q 'disable is incomplete' "$EDITED_INTERRUPT_ROOT/disable.out"
[[ -f "$XDG_STATE_HOME/omafiles/integrations/enabling" ]]
[[ -f "$XDG_STATE_HOME/omafiles/integrations/transaction/mime.completed-hash" ]]

! grep -R -E -q '(^| )restart xdg-desktop-portal' "$TOP"/*/systemctl.log
cat "$TOP"/*/systemctl.log | grep -q 'try-restart xdg-desktop-portal'
echo "isolated integration lifecycle: PASS"

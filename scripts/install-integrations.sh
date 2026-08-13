#!/bin/bash
# Self-registers Omafiles as the system file manager: .desktop with
# MimeType=inode/directory (xdg-open/"Open folder") + the D-Bus service
# org.freedesktop.FileManager1 ("Show in file manager" of Firefox/GTK/Qt).
# It's launched by the app on startup (core/AppBindings.qml) from
# <resourceDir>/scripts/, so no one has to run it by hand.
#
# Idempotent and versioned: it doesn't repeat the work on every shell startup,
# only the first time or when INTEGRATION_VERSION goes up (if the template
# changes in the future). If the user reverts the default by hand afterward,
# we don't clobber it again until we bump the version.

set -euo pipefail

# Real bug (audit 2026-08-05): with "set -e", any step that
# failed midway aborted the script silently -- STATE_FILE was never
# written, so the next shell startup retried
# the same failed step forever, without any visible notice (stderr of
# xdg-mime/dbus-send already went to /dev/null on purpose). This trap ensures
# that at least ONE notification is seen that something failed, instead of a
# mute failure repeating on every startup without anyone noticing.
on_error() {
  command -v notify-send >/dev/null 2>&1 && notify-send \
    "Omafiles" "Failed to set up default-file-manager integrations. Will retry on next launch." >/dev/null 2>&1
}
trap on_error ERR

# Phase 29: v4 moved the .desktop Exec paths and the D-Bus services from the repo
# to the stable XDG location ($XDG_DATA_HOME/omafiles); v5 added the official
# icon + its symbolic variant; v6 adds StartupWMClass=omafiles (so that the
# dock/taskbar matches the window with this .desktop and paints the icon); v7
# fixes D-Bus service section headers and system python shebangs; v8 adds the
# org.freedesktop.impl.portal.FileChooser integration. Bumping the version
# forces the rewrite and re-copy in earlier installations.
INTEGRATION_VERSION=8

# RES_DIR: STABLE root of installed resources (Phase 29). The Exec point here,
# not to the repo, so deleting the repository doesn't break opening folders nor "show in
# file manager". Requires `cmake --install` (which copies scripts/ and assets/ here).
RES_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/omafiles"
# SELF_RES: the resource root where THIS script lives (to read the icon without
# depending on the install having already run). In an installation == RES_DIR.
SELF_RES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omafiles"
STATE_FILE="$STATE_DIR/integrations-version"

# Phase 29: idempotent migration of the inherited config. actions.toml moved from
# ~/.config/omarchy/omafiles/ to its own XDG config (~/.config/omafiles/). It goes
# BEFORE the version early-exit, so it runs even if the integrations are already
# up to date. It only copies if the old one exists and the new one doesn't yet, and does NOT
# delete the old one (in case the user still runs an old version in parallel).
LEGACY_ACTIONS="$HOME/.config/omarchy/omafiles/actions.toml"
NEW_ACTIONS="${XDG_CONFIG_HOME:-$HOME/.config}/omafiles/actions.toml"
if [[ -f "$LEGACY_ACTIONS" && ! -e "$NEW_ACTIONS" ]]; then
  mkdir -p "$(dirname "$NEW_ACTIONS")"
  cp "$LEGACY_ACTIONS" "$NEW_ACTIONS" 2>/dev/null || true
fi

mkdir -p "$STATE_DIR"
if [[ -f $STATE_FILE ]] && [[ "$(cat "$STATE_FILE" 2>/dev/null)" == "$INTEGRATION_VERSION" ]]; then
  exit 0
fi

XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS_DIR="$XDG_DATA/applications"
DBUS_SERVICES_DIR="$XDG_DATA/dbus-1/services"
ICON_DIR="$XDG_DATA/icons/hicolor/scalable/apps"
PORTALS_DIR="$XDG_DATA/xdg-desktop-portal/portals"
mkdir -p "$APPS_DIR" "$DBUS_SERVICES_DIR" "$ICON_DIR" "$PORTALS_DIR"

# Real bug: the .desktop below references Icon=omafiles, but nothing
# ever installed the SVG itself -- it was placed by hand on this specific
# machine, so a new machine (or a rebuilt ~/.local/share/icons)
# would be left with the generic "file manager" icon
# without any notice. Now the SVG lives in the repo itself
# (assets/omafiles.svg) and this script installs it like any other
# integration.
for _ic in omafiles.svg omafiles-symbolic.svg; do
  [[ -f "$SELF_RES/assets/$_ic" ]] && cp -f "$SELF_RES/assets/$_ic" "$ICON_DIR/$_ic"
done

# reverse-DNS ID: mandatory for the D-Bus activation of the .desktop (a valid
# bus name needs dots; plain "omafiles" won't do).
APP_ID=io.github.percius04.omafiles

# .desktop DBusActivatable (v3). Firefox/Zen "open containing folder" does NOT use
# xdg-mime nor org.freedesktop.FileManager1: it activates the default manager via
# org.freedesktop.Application.Open, and only does so with DBusActivatable managers
# (Nautilus is one by being a GApplication). Without this, Zen resolved the default
# (omafiles) but couldn't activate it over D-Bus and fell back to Nautilus. It replaces the
# old omafiles.desktop (not activatable).
rm -f "$APPS_DIR/omafiles.desktop"
cat >"$APPS_DIR/$APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Omafiles
GenericName=File manager
Comment=Custom file manager for Omarchy
Exec=$RES_DIR/scripts/open-path.sh %u
Icon=omafiles
Terminal=false
Categories=System;FileManager;
MimeType=inode/directory;
DBusActivatable=true
StartupWMClass=omafiles
EOF

# D-Bus service of org.freedesktop.Application (the interface that activates the
# DBusActivatable .desktop). The Name MUST be the same id as the .desktop.
cat >"$DBUS_SERVICES_DIR/$APP_ID.service" <<EOF
[D-BUS Service]
Name=$APP_ID
Exec=$RES_DIR/scripts/dbus-app-open.py
EOF

# D-Bus service org.freedesktop.FileManager1 ("Show in file manager" of
# GTK/Qt apps that do use this interface).
cat >"$DBUS_SERVICES_DIR/org.freedesktop.FileManager1.service" <<EOF
[D-BUS Service]
Name=org.freedesktop.FileManager1
Exec=$RES_DIR/scripts/dbus-filemanager1.py
EOF

# D-Bus service org.freedesktop.impl.portal.desktop.omafiles
cat >"$DBUS_SERVICES_DIR/org.freedesktop.impl.portal.desktop.omafiles.service" <<EOF
[D-BUS Service]
Name=org.freedesktop.impl.portal.desktop.omafiles
Exec=$RES_DIR/scripts/dbus-filechooser.py
EOF

# xdg-desktop-portal backend configuration file
cat >"$PORTALS_DIR/omafiles.portal" <<EOF
[portal]
DBusName=org.freedesktop.impl.portal.desktop.omafiles
Interfaces=org.freedesktop.impl.portal.FileChooser;
UseIn=omarchy;Hyprland;
EOF

# User portal configuration
USER_PORTAL_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/xdg-desktop-portal"
USER_HYPRLAND_PORTALS_CONF="$USER_PORTAL_CONF_DIR/hyprland-portals.conf"
USER_PORTALS_CONF="$USER_PORTAL_CONF_DIR/portals.conf"
mkdir -p "$USER_PORTAL_CONF_DIR"

ensure_filechooser_portal() {
  local conf_file="$1"
  local default_content="$2"
  if [[ ! -f "$conf_file" ]]; then
    echo -e "$default_content" > "$conf_file"
  fi

  if ! grep -q "org.freedesktop.impl.portal.FileChooser" "$conf_file"; then
    if grep -q "\[preferred\]" "$conf_file"; then
      sed -i '/\[preferred\]/a org.freedesktop.impl.portal.FileChooser=omafiles' "$conf_file"
    else
      echo -e "\n[preferred]\norg.freedesktop.impl.portal.FileChooser=omafiles" >> "$conf_file"
    fi
  else
    sed -i 's/^org.freedesktop.impl.portal.FileChooser=.*/org.freedesktop.impl.portal.FileChooser=omafiles/' "$conf_file"
  fi
}

ensure_filechooser_portal "$USER_HYPRLAND_PORTALS_CONF" "[preferred]\ndefault=hyprland;gtk"
ensure_filechooser_portal "$USER_PORTALS_CONF" "[preferred]\ndefault=gtk"

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" >/dev/null 2>&1
command -v xdg-mime >/dev/null 2>&1 && xdg-mime default "$APP_ID.desktop" inode/directory >/dev/null 2>&1

# If something (typically Nautilus) already activated and took the bus name before
# our .service existed, we force a rescan so that the next
# ShowItems/ShowFolders reaches us without waiting for the next login.
command -v dbus-send >/dev/null 2>&1 && dbus-send --session --type=method_call \
  --dest=org.freedesktop.DBus /org/freedesktop/DBus \
  org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1

# Restart xdg-desktop-portal user service so it picks up our new portal configuration
systemctl --user restart xdg-desktop-portal >/dev/null 2>&1 || true

echo -n "$INTEGRATION_VERSION" >"$STATE_FILE"

# Standard notify-send (freedesktop), independent of Omarchy. The icon is the
# app's own (Icon=omafiles already installed in hicolor).
command -v notify-send >/dev/null 2>&1 && notify-send -i omafiles \
  "Omafiles" "Set as the default file manager and FileChooser portal." >/dev/null 2>&1

exit 0

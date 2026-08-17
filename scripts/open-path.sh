#!/bin/bash
# Opens Omafiles at a specific path. It's invoked by the .desktop (MimeType=
# inode/directory, %u) when another app or xdg-open ask to open a folder.
# $1 = absolute path or file:// URI (whatever the mimetype handler sends);
# empty for the normal launch from the applications menu.

arg="$1"
path=""

if [[ -n "$arg" ]]; then
  if [[ "$arg" == file://* ]]; then
    encoded="${arg#file://}"
    # Discards a possible host component (file://host/path) -- same
    # criterion as urlparse() in dbus-filemanager1.py. No real
    # case that generates it has been seen on this system, but it's free
    # to cover it while we're here.
    if [[ "$encoded" != /* ]]; then
      encoded="/${encoded#*/}"
    fi
    # Percent-decoding only -- real bug: the "+"->space substitution that
    # was here before is the application/x-www-form-urlencoded convention,
    # NOT that of a file:// URI (RFC 3986), where a literal "+" in a
    # real name ("C++", "backup+2024") is never encoded as a space.
    # It turned "C++ notes.txt" into "C   notes.txt" (which doesn't exist), so
    # opening any file/folder with "+" in the name from another
    # app (xdg-open, "Open with Omafiles"...) landed nowhere,
    # silently.
    path="$(printf '%b' "${encoded//%/\\x}")"
  else
    path="$arg"
  fi

  [[ -f "$path" ]] && path="$(dirname -- "$path")"
  [[ -d "$path" ]] || path=""
fi

# Resolve an explicit package/test override first, then PATH, then the standard
# per-user fallback. Never assume a system package lives under ~/.local.
omafiles_bin="${OMAFILES_BIN:-}"
if [[ -z "$omafiles_bin" ]]; then
  omafiles_bin="$(command -v omafiles 2>/dev/null || true)"
fi
if [[ -z "$omafiles_bin" && -x "$HOME/.local/bin/omafiles" ]]; then
  omafiles_bin="$HOME/.local/bin/omafiles"
fi
if [[ -z "$omafiles_bin" || ! -x "$omafiles_bin" ]]; then
  printf 'OmaFiles: executable not found (set OMAFILES_BIN or install omafiles in PATH).\n' >&2
  exit 127
fi

# If Omafiles is already open, its single instance receives the path and
# navigates to it. Empty path restores the previous session.
exec "$omafiles_bin" "$path"

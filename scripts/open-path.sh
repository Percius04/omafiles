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

# Launches whichever installation is active. The PATH lookup supports package
# managers such as Nix; the fallback preserves the direct CMake installation.
# If Omafiles is already open, its single instance receives the path and
# navigates to it in a new tab, bringing the window to the front.
omafiles_bin="$(command -v omafiles || true)"
if [[ -z "$omafiles_bin" && -x "$HOME/.local/bin/omafiles" ]]; then
  omafiles_bin="$HOME/.local/bin/omafiles"
fi
if [[ -z "$omafiles_bin" ]]; then
  printf 'omafiles: executable not found in PATH or ~/.local/bin\n' >&2
  exit 127
fi

exec "$omafiles_bin" "$path"

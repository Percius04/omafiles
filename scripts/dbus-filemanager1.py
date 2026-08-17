#!/usr/bin/python3
"""org.freedesktop.FileManager1 backend for OmaFiles."""

import json
import os
import shutil
import sys
import urllib.parse
from pathlib import Path

BUS_NAME = "org.freedesktop.FileManager1"
OBJECT_PATH = "/org/freedesktop/FileManager1"
VALID_ACTIONS = {"show-items", "show-folders", "show-properties"}

INTROSPECTION_XML = """
<node>
  <interface name="org.freedesktop.FileManager1">
    <method name="ShowFolders">
      <arg type="as" name="URIs" direction="in"/>
      <arg type="s" name="StartupId" direction="in"/>
    </method>
    <method name="ShowItems">
      <arg type="as" name="URIs" direction="in"/>
      <arg type="s" name="StartupId" direction="in"/>
    </method>
    <method name="ShowItemProperties">
      <arg type="as" name="URIs" direction="in"/>
      <arg type="s" name="StartupId" direction="in"/>
    </method>
  </interface>
</node>
"""


def valid_basename(name):
    return (
        isinstance(name, str)
        and bool(name)
        and name not in (".", "..")
        and "/" not in name
        and "\0" not in name
    )


def uri_to_path(uri):
    if not isinstance(uri, str):
        return None
    parsed = urllib.parse.urlsplit(uri)
    if parsed.scheme not in ("file", "") or parsed.netloc or parsed.query or parsed.fragment:
        return None
    try:
        path = urllib.parse.unquote(parsed.path, errors="strict")
    except (UnicodeDecodeError, ValueError):
        return None
    if not os.path.isabs(path) or "\0" in path:
        return None
    return os.path.normpath(path)


def build_file_manager_payload(action, folder, basenames):
    """Return the strict, non-secret JSON accepted by the normal instance."""
    if action not in VALID_ACTIONS:
        raise ValueError("invalid file-manager action")
    if not isinstance(folder, str) or not os.path.isabs(folder) or "\0" in folder:
        raise ValueError("folder must be an absolute path")
    names = list(basenames)
    if any(not valid_basename(name) for name in names):
        raise ValueError("invalid basename")
    if action == "show-folders" and names:
        raise ValueError("show-folders must not select basenames")
    if action != "show-folders" and not names:
        raise ValueError("item actions require basenames")
    return json.dumps(
        {
            "kind": "file-manager",
            "action": action,
            "folder": os.path.normpath(folder),
            "basenames": names,
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )


def payloads_for_uris(uris, action):
    """Group URI requests into one validated payload per target folder."""
    if action not in VALID_ACTIONS:
        raise ValueError("invalid file-manager action")
    if action == "show-folders":
        folders = []
        for uri in uris:
            path = uri_to_path(uri)
            if not path:
                continue
            target = path if Path(path).is_dir() else str(Path(path).parent)
            if target not in folders:
                folders.append(target)
        return [build_file_manager_payload(action, folder, []) for folder in folders]

    groups = {}
    order = []
    for uri in uris:
        path = uri_to_path(uri)
        if not path:
            continue
        item = Path(path)
        parent = str(item.parent)
        if not valid_basename(item.name):
            continue
        if parent not in groups:
            groups[parent] = []
            order.append(parent)
        groups[parent].append(item.name)
    return [build_file_manager_payload(action, parent, groups[parent]) for parent in order]


def resolve_omafiles_bin():
    return shutil.which("omafiles") or str(Path.home() / ".local" / "bin" / "omafiles")


def summon(payload, Gio, GLib):
    try:
        Gio.Subprocess.new([resolve_omafiles_bin(), payload], Gio.SubprocessFlags.NONE)
    except GLib.Error as exc:
        print("omafiles FileManager1: failed to launch omafiles:", exc, file=sys.stderr)


def make_method_handler(Gio, GLib):
    actions = {
        "ShowItems": "show-items",
        "ShowFolders": "show-folders",
        "ShowItemProperties": "show-properties",
    }

    def on_method_call(connection, sender, object_path, interface_name,
                       method_name, parameters, invocation):
        del connection, sender, object_path, interface_name
        uris, _startup_id = parameters.unpack()
        action = actions.get(method_name)
        if action:
            for payload in payloads_for_uris(uris, action):
                summon(payload, Gio, GLib)
        invocation.return_value(None)

    return on_method_call


def main():
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib

    loop = GLib.MainLoop()
    handler = make_method_handler(Gio, GLib)

    def on_bus_acquired(connection, name):
        del name
        node_info = Gio.DBusNodeInfo.new_for_xml(INTROSPECTION_XML)
        connection.register_object(
            OBJECT_PATH, node_info.interfaces[0], handler, None, None
        )

    def on_name_lost(connection, name):
        del connection, name
        loop.quit()

    Gio.bus_own_name(
        Gio.BusType.SESSION,
        BUS_NAME,
        Gio.BusNameOwnerFlags.NONE,
        on_bus_acquired,
        None,
        on_name_lost,
    )
    loop.run()


if __name__ == "__main__":
    main()

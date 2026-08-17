#!/usr/bin/python3
"""org.freedesktop.impl.portal.FileChooser backend for OmaFiles."""

import hmac
import json
import os
import posixpath
import re
import secrets
import shutil
import sys
from pathlib import Path
from urllib.parse import unquote_to_bytes, urlsplit

BUS_NAME = "org.freedesktop.impl.portal.desktop.omafiles"
OBJECT_PATH = "/org/freedesktop/portal/desktop"

INTROSPECTION_XML = """
<node>
  <interface name="org.freedesktop.impl.portal.FileChooser">
    <method name="OpenFile">
      <arg type="o" name="handle" direction="in"/>
      <arg type="s" name="app_id" direction="in"/>
      <arg type="s" name="parent_window" direction="in"/>
      <arg type="s" name="title" direction="in"/>
      <arg type="a{sv}" name="options" direction="in"/>
      <arg type="u" name="response" direction="out"/>
      <arg type="a{sv}" name="results" direction="out"/>
    </method>
    <method name="SaveFile">
      <arg type="o" name="handle" direction="in"/>
      <arg type="s" name="app_id" direction="in"/>
      <arg type="s" name="parent_window" direction="in"/>
      <arg type="s" name="title" direction="in"/>
      <arg type="a{sv}" name="options" direction="in"/>
      <arg type="u" name="response" direction="out"/>
      <arg type="a{sv}" name="results" direction="out"/>
    </method>
    <method name="SaveFiles">
      <arg type="o" name="handle" direction="in"/>
      <arg type="s" name="app_id" direction="in"/>
      <arg type="s" name="parent_window" direction="in"/>
      <arg type="s" name="title" direction="in"/>
      <arg type="a{sv}" name="options" direction="in"/>
      <arg type="u" name="response" direction="out"/>
      <arg type="a{sv}" name="results" direction="out"/>
    </method>
  </interface>

  <interface name="org.freedesktop.impl.portal.desktop.omafiles">
    <method name="RegisterPicker">
      <arg type="s" name="requestId" direction="in"/>
      <arg type="s" name="token" direction="in"/>
    </method>
    <method name="SubmitResponse">
      <arg type="s" name="requestId" direction="in"/>
      <arg type="u" name="responseCode" direction="in"/>
      <arg type="s" name="resultsJson" direction="in"/>
    </method>
  </interface>
</node>
"""

REQUEST_INTROSPECTION_XML = """
<node>
  <interface name="org.freedesktop.impl.portal.Request">
    <method name="Close"/>
  </interface>
</node>
"""

Gio = None
GLib = None
loop = None
dbus_connection = None
active_requests = {}


def _as_bytes(value):
    if isinstance(value, bytes):
        return value
    if isinstance(value, bytearray):
        return bytes(value)
    try:
        return bytes(value)
    except (TypeError, ValueError) as exc:
        raise ValueError("expected a byte array") from exc


def decode_nul_path(value):
    """Decode a portal ay path, accepting a missing final NUL for compatibility."""
    raw = _as_bytes(value)
    if raw.endswith(b"\0"):
        raw = raw[:-1]
    if b"\0" in raw:
        raise ValueError("path contains an embedded NUL")
    return raw.decode("utf-8")


def valid_basename(name):
    return bool(name) and name not in (".", "..") and "/" not in name and "\0" not in name


def decode_save_files(value):
    """Decode ordered aay SaveFiles names and enforce one-component basenames."""
    names = []
    for item in value or []:
        raw = _as_bytes(item)
        if not raw.endswith(b"\0") or raw.count(b"\0") != 1:
            raise ValueError("SaveFiles names must have one terminal NUL")
        name = raw[:-1].decode("utf-8")
        if not valid_basename(name):
            raise ValueError("SaveFiles name is not a valid basename")
        names.append(name)
    if not names:
        raise ValueError("SaveFiles requires at least one basename")
    return names


def build_picker_payload(*, folder, request_id, mode, multiple, suggested_name, files):
    """Build the non-secret JSON argument consumed by OmafilesContent.open()."""
    return json.dumps(
        {
            "kind": "picker",
            "folder": folder,
            "requestId": request_id,
            "mode": mode,
            "multiple": bool(multiple),
            "suggestedName": suggested_name or "",
            "files": list(files or []),
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )


def sender_matches_request(requests, request_id, sender):
    request = requests.get(request_id)
    return bool(request) and request.get("picker_sender") == sender


def claim_request(requests, request_id):
    """Take an active request once so racing callbacks cannot answer twice."""
    return requests.pop(request_id, None)


def _decode_local_uri(uri):
    if not isinstance(uri, str) or re.search(r"%(?![0-9A-Fa-f]{2})", uri):
        raise ValueError("invalid URI or percent escape")
    parsed = urlsplit(uri)
    if parsed.scheme != "file" or parsed.netloc or parsed.query or parsed.fragment:
        raise ValueError("result must be a local file URI")
    raw_path = unquote_to_bytes(parsed.path)
    path = raw_path.decode("utf-8")
    if not path.startswith("/") or "\0" in path:
        raise ValueError("result path must be an absolute local path")
    if any(part in (".", "..") for part in path.split("/")):
        raise ValueError("result path contains traversal")
    return path


def normalize_submission(response_code, results_json, mode, multiple, requested_files):
    """Validate a picker submission before returning it to the portal caller."""
    if response_code not in (0, 1, 2):
        return 2, []
    if response_code != 0:
        return response_code, []
    try:
        uris = json.loads(results_json)
        if not isinstance(uris, list) or not uris:
            raise ValueError("results must be a non-empty list")
        paths = [_decode_local_uri(uri) for uri in uris]
    except (TypeError, UnicodeDecodeError, ValueError):
        return 2, []

    if mode == "save-files":
        if [posixpath.basename(path) for path in paths] != list(requested_files or []):
            return 2, []
        parents = [posixpath.dirname(path) for path in paths]
        if not parents or any(parent != parents[0] for parent in parents):
            return 2, []
    elif mode == "open-file":
        if any(os.path.isdir(path) for path in paths):
            return 2, []
        if not multiple and len(uris) > 1:
            uris = uris[:1]
    elif not multiple and len(uris) > 1:
        uris = uris[:1]
    return 0, uris


def get_opt(options, key, default=None):
    if key not in options:
        return default
    value = options[key]
    return value.unpack() if hasattr(value, "unpack") else value


def resolve_omafiles_bin():
    override = os.environ.get("OMAFILES_BIN")
    if override:
        return override
    return shutil.which("omafiles") or str(Path.home() / ".local" / "bin" / "omafiles")


def _cleanup_claimed_request(request):
    if dbus_connection:
        try:
            dbus_connection.unregister_object(request["registration_id"])
        except Exception as exc:
            print(
                f"OmaFiles FileChooser: failed to unregister request object: {exc}",
                file=sys.stderr,
            )


def complete_request(handle, response_code, uris=None, force_exit=False):
    """Complete and clean a request once; optionally terminate its picker."""
    request = claim_request(active_requests, handle)
    if not request:
        return False
    _cleanup_claimed_request(request)
    results = {"uris": GLib.Variant("as", uris or [])} if response_code == 0 else {}
    request["invocation"].return_value(GLib.Variant("(ua{sv})", (response_code, results)))
    process = request.get("process")
    if force_exit and process:
        try:
            process.force_exit()
        except Exception:
            pass
    return True


def request_method_call(connection, sender, object_path, interface_name,
                        method_name, parameters, invocation):
    if method_name == "Close":
        complete_request(object_path, 1, force_exit=True)
        invocation.return_value(None)


def _decode_option_path(options, key):
    value = get_opt(options, key, b"")
    if not value:
        return ""
    try:
        return decode_nul_path(value)
    except (UnicodeDecodeError, ValueError):
        return ""


def on_filechooser_method_call(connection, sender, object_path, interface_name,
                               method_name, parameters, invocation):
    handle, _app_id, _parent_window, _title, options = parameters.unpack()
    multiple = bool(get_opt(options, "multiple", False))
    directory = bool(get_opt(options, "directory", False))

    folder_path = _decode_option_path(options, "current_folder")
    suggested_name = get_opt(options, "current_name", "") or ""
    if not suggested_name:
        current_file = _decode_option_path(options, "current_file")
        if current_file:
            current_path = Path(current_file)
            suggested_name = current_path.name
            if not folder_path:
                folder_path = str(current_path.parent)
    if not folder_path or not Path(folder_path).is_dir():
        folder_path = str(Path.home())

    files = []
    if method_name == "SaveFiles":
        mode = "save-files"
        try:
            files = decode_save_files(get_opt(options, "files", []))
        except (UnicodeDecodeError, ValueError) as exc:
            print(f"OmaFiles FileChooser: invalid SaveFiles names: {exc}", file=sys.stderr)
            invocation.return_value(GLib.Variant("(ua{sv})", (2, {})))
            return
    elif method_name == "SaveFile":
        mode = "save-file"
    elif directory:
        mode = "open-dir"
    else:
        mode = "open-file"

    request_node = Gio.DBusNodeInfo.new_for_xml(REQUEST_INTROSPECTION_XML)
    registration_id = connection.register_object(
        handle, request_node.interfaces[0], request_method_call, None, None
    )
    token = secrets.token_urlsafe(32)
    active_requests[handle] = {
        "invocation": invocation,
        "registration_id": registration_id,
        "multiple": multiple,
        "mode": mode,
        "files": files,
        "token": token,
        "picker_sender": None,
        "process": None,
    }

    def on_proc_finished(process, result, request_handle):
        try:
            process.wait_finish(result)
        except GLib.Error:
            pass
        complete_request(request_handle, 1)

    payload = build_picker_payload(
        folder=folder_path,
        request_id=handle,
        mode=mode,
        multiple=multiple,
        suggested_name=suggested_name,
        files=files,
    )
    try:
        process = Gio.Subprocess.new(
            [resolve_omafiles_bin(), payload], Gio.SubprocessFlags.STDIN_PIPE
        )
        active_requests[handle]["process"] = process
        input_stream = process.get_stdin_pipe()
        input_stream.write_all((token + "\n").encode("ascii"), None)
        input_stream.close(None)
        process.wait_async(None, on_proc_finished, handle)
    except GLib.Error as exc:
        print(f"OmaFiles FileChooser: failed to launch picker: {exc}", file=sys.stderr)
        complete_request(handle, 2, force_exit=True)


def _invalid_request(invocation):
    invocation.return_dbus_error(
        "org.freedesktop.impl.portal.desktop.omafiles.InvalidRequest",
        "No matching active picker request",
    )


def on_submission_method_call(connection, sender, object_path, interface_name,
                              method_name, parameters, invocation):
    if method_name == "RegisterPicker":
        request_id, submitted_token = parameters.unpack()
        request = active_requests.get(request_id)
        if (
            not request
            or not sender.startswith(":")
            or request.get("picker_sender") is not None
            or not hmac.compare_digest(request.get("token", ""), submitted_token)
        ):
            _invalid_request(invocation)
            return
        request["picker_sender"] = sender
        request.pop("token", None)
        invocation.return_value(None)
        return

    if method_name != "SubmitResponse":
        return
    request_id, response_code, results_json = parameters.unpack()
    if not sender_matches_request(active_requests, request_id, sender):
        _invalid_request(invocation)
        return
    request = active_requests[request_id]
    response_code, uris = normalize_submission(
        response_code,
        results_json,
        request["mode"],
        request["multiple"],
        request["files"],
    )
    if not complete_request(request_id, response_code, uris):
        _invalid_request(invocation)
        return
    invocation.return_value(None)


def on_bus_acquired(connection, name):
    global dbus_connection
    dbus_connection = connection
    node_info = Gio.DBusNodeInfo.new_for_xml(INTROSPECTION_XML)
    connection.register_object(
        OBJECT_PATH, node_info.interfaces[0], on_filechooser_method_call, None, None
    )
    connection.register_object(
        OBJECT_PATH, node_info.interfaces[1], on_submission_method_call, None, None
    )


def on_name_lost(connection, name):
    loop.quit()


def main():
    global Gio, GLib, loop
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio as GioModule, GLib as GLibModule

    Gio = GioModule
    GLib = GLibModule
    loop = GLib.MainLoop()
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

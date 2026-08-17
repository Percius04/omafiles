#!/usr/bin/python3
"""org.freedesktop.impl.portal.FileChooser backend for OmaFiles."""

import fnmatch
import hmac
import json
import mimetypes
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
FRONTEND_BUS_NAME = "org.freedesktop.portal.Desktop"

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
frontend_owner = ""
active_requests = {}

# Linux accepts at most 32 pages for one execve(2) argument (MAX_ARG_STRLEN),
# including its terminating NUL. The picker JSON is one argument, so this is
# the technical bound for the full payload, each nested UTF-8 string, and each
# collection count (every serialized item consumes at least one byte).
MAX_PICKER_ARGUMENT_BYTES = os.sysconf("SC_PAGESIZE") * 32 - 1
MAX_PICKER_STRING_BYTES = MAX_PICKER_ARGUMENT_BYTES
MAX_PICKER_COLLECTION_ITEMS = MAX_PICKER_ARGUMENT_BYTES
_MIME_PATTERN = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9!#$&^_.+\-]*/(?:\*|[A-Za-z0-9][A-Za-z0-9!#$&^_.+\-]*)$"
)


def validate_collection_count(value, label):
    try:
        count = len(value)
    except TypeError as exc:
        raise ValueError(f"{label} must be an array") from exc
    if count > MAX_PICKER_COLLECTION_ITEMS:
        raise ValueError(f"{label} has too many items")
    return count


def _valid_text(value, label, *, allow_empty=False):
    if not isinstance(value, str) or (not allow_empty and not value) or "\0" in value:
        raise ValueError(f"{label} is invalid")
    try:
        encoded = value.encode("utf-8", "strict")
    except UnicodeEncodeError as exc:
        raise ValueError(f"{label} is not valid UTF-8") from exc
    if len(encoded) > MAX_PICKER_STRING_BYTES:
        raise ValueError(f"{label} is too large")
    return value


def _sequence(value, length, label):
    if not isinstance(value, (list, tuple)) or len(value) != length:
        raise ValueError(f"{label} has the wrong tuple shape")
    return value


def decode_filters(value):
    """Decode a(sa(us)) into JSON-safe filters and canonical D-Bus tuples."""
    if not isinstance(value, (list, tuple)):
        raise ValueError("filters must be an array")
    validate_collection_count(value, "filters")
    decoded = []
    originals = []
    for filter_index, raw_filter in enumerate(value):
        name, raw_rules = _sequence(raw_filter, 2, f"filter {filter_index}")
        name = _valid_text(name, f"filter {filter_index} name")
        if not isinstance(raw_rules, (list, tuple)):
            raise ValueError(f"filter {filter_index} rules must be an array")
        if not raw_rules:
            raise ValueError(f"filter {filter_index} must have a rule")
        validate_collection_count(raw_rules, f"filter {filter_index} rules")
        rules = []
        original_rules = []
        for rule_index, raw_rule in enumerate(raw_rules):
            rule_type, rule_value = _sequence(
                raw_rule, 2, f"filter {filter_index} rule {rule_index}"
            )
            if type(rule_type) is not int or rule_type not in (0, 1):
                raise ValueError("filter rule type must be glob=0 or MIME=1")
            rule_value = _valid_text(
                rule_value, f"filter {filter_index} rule {rule_index} value"
            )
            if rule_type == 1 and not _MIME_PATTERN.fullmatch(rule_value):
                raise ValueError("invalid MIME filter")
            rules.append({"type": rule_type, "value": rule_value})
            original_rules.append((rule_type, rule_value))
        decoded.append({"name": name, "rules": rules})
        originals.append((name, tuple(original_rules)))
    return decoded, originals


def decode_current_filter(value, filters):
    """Return the exact matching filter index for a (sa(us)) value."""
    decoded, originals = decode_filters([_sequence(value, 2, "current_filter")])
    del decoded
    if not filters:
        raise ValueError("current_filter requires filters")
    try:
        return list(filters).index(originals[0])
    except ValueError as exc:
        raise ValueError("current_filter is not in filters") from exc


def decode_choices(value):
    """Decode a(ssa(ss)s) into JSON-safe choices and canonical tuples."""
    if not isinstance(value, (list, tuple)):
        raise ValueError("choices must be an array")
    validate_collection_count(value, "choices")
    decoded = []
    originals = []
    choice_ids = set()
    for choice_index, raw_choice in enumerate(value):
        choice_id, label, raw_options, selected = _sequence(
            raw_choice, 4, f"choice {choice_index}"
        )
        choice_id = _valid_text(choice_id, f"choice {choice_index} id")
        label = _valid_text(label, f"choice {choice_index} label")
        selected = _valid_text(selected, f"choice {choice_index} initial selection")
        if choice_id in choice_ids:
            raise ValueError("choice IDs must be unique")
        choice_ids.add(choice_id)
        if not isinstance(raw_options, (list, tuple)):
            raise ValueError(f"choice {choice_index} options must be an array")
        validate_collection_count(raw_options, f"choice {choice_index} options")
        options = []
        original_options = []
        option_ids = set()
        for option_index, raw_option in enumerate(raw_options):
            option_id, option_label = _sequence(
                raw_option, 2, f"choice {choice_index} option {option_index}"
            )
            option_id = _valid_text(
                option_id, f"choice {choice_index} option {option_index} id"
            )
            option_label = _valid_text(
                option_label, f"choice {choice_index} option {option_index} label"
            )
            if option_id in option_ids:
                raise ValueError("choice option IDs must be unique")
            option_ids.add(option_id)
            options.append({"id": option_id, "label": option_label})
            original_options.append((option_id, option_label))
        if options:
            if selected not in option_ids:
                raise ValueError("choice initial selection is not an option")
        elif selected not in ("true", "false"):
            raise ValueError("boolean choice selection must be true or false")
        decoded.append(
            {
                "id": choice_id,
                "label": label,
                "options": options,
                "selected": selected,
            }
        )
        originals.append((choice_id, label, tuple(original_options), selected))
    return decoded, originals


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


def build_picker_payload(
    *, folder, request_id, mode, multiple, suggested_name, files,
    filters, current_filter, choices
):
    """Build the bounded, non-secret JSON argument consumed by the picker."""
    payload = json.dumps(
        {
            "kind": "picker",
            "folder": folder,
            "requestId": request_id,
            "mode": mode,
            "multiple": bool(multiple),
            "suggestedName": suggested_name or "",
            "files": list(files or []),
            "filters": list(filters),
            "currentFilter": current_filter,
            "choices": list(choices),
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )
    try:
        encoded = payload.encode("utf-8", "strict")
    except UnicodeEncodeError as exc:
        raise ValueError("picker payload is not valid UTF-8") from exc
    if len(encoded) > MAX_PICKER_ARGUMENT_BYTES:
        raise ValueError("picker payload exceeds the Linux single-argument limit")
    return payload


def sender_matches_request(requests, request_id, sender):
    request = requests.get(request_id)
    return bool(request) and request.get("picker_sender") == sender


def _authorization_error(invocation, message):
    invocation.return_dbus_error(
        "org.freedesktop.impl.portal.desktop.omafiles.NotAuthorized", message
    )


def require_frontend_sender(sender, invocation):
    """Accept portal methods only from the current Desktop frontend owner."""
    if frontend_owner and sender == frontend_owner:
        return True
    _authorization_error(invocation, "Caller is not the portal frontend owner")
    return False


def require_new_handle(requests, handle, invocation):
    """Reject a duplicate active request without replacing its state."""
    if handle not in requests:
        return True
    invocation.return_dbus_error(
        "org.freedesktop.impl.portal.desktop.omafiles.DuplicateHandle",
        "Request handle is already active",
    )
    return False


def frontend_sender_matches(requests, request_id, sender):
    request = requests.get(request_id)
    return bool(request) and request.get("frontend_sender") == sender


def frontend_request_handles(requests, sender):
    return [
        handle
        for handle, request in requests.items()
        if request.get("frontend_sender") == sender
    ]


def resolve_frontend_owner(connection):
    """Resolve the unique owner of org.freedesktop.portal.Desktop."""
    reply = connection.call_sync(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "GetNameOwner",
        GLib.Variant("(s)", (FRONTEND_BUS_NAME,)),
        GLib.VariantType.new("(s)"),
        0,
        -1,
        None,
    )
    return reply.unpack()[0]


def on_frontend_owner_changed(connection, sender_name, object_path, interface_name,
                              signal_name, parameters, user_data=None):
    del connection, sender_name, object_path, interface_name, signal_name, user_data
    global frontend_owner
    name, old_owner, new_owner = parameters.unpack()
    if name != FRONTEND_BUS_NAME:
        return
    frontend_owner = new_owner
    for handle in frontend_request_handles(active_requests, old_owner):
        complete_request(handle, 1, force_exit=True)


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


def _mime_type_for_path(path):
    if Gio is not None:
        try:
            content_type, _uncertain = Gio.content_type_guess(path, None)
            if content_type:
                return content_type
        except (AttributeError, TypeError):
            pass
    return mimetypes.guess_type(path, strict=False)[0] or "application/octet-stream"


def _mime_matches(actual, expected):
    if expected.endswith("/*"):
        return actual.startswith(expected[:-1])
    if actual == expected:
        return True
    if Gio is not None:
        try:
            return Gio.content_type_is_a(actual, expected)
        except (AttributeError, TypeError):
            return False
    return False


def path_matches_filter(path, selected_filter):
    """Match a local path against one normalized canonical filter tuple."""
    _name, rules = selected_filter
    basename = posixpath.basename(path)
    actual_mime = None
    for rule_type, rule_value in rules:
        if rule_type == 0 and fnmatch.fnmatchcase(basename, rule_value):
            return True
        if rule_type == 1:
            if actual_mime is None:
                actual_mime = _mime_type_for_path(path)
            if _mime_matches(actual_mime, rule_value):
                return True
    return False


def _normalize_choice_submission(submitted, requested_choices):
    if not isinstance(submitted, list):
        raise ValueError("choices must be an array")
    validate_collection_count(submitted, "submitted choices")
    values = {}
    for pair_index, raw_pair in enumerate(submitted):
        choice_id, value = _sequence(raw_pair, 2, f"submitted choice {pair_index}")
        choice_id = _valid_text(choice_id, f"submitted choice {pair_index} id")
        value = _valid_text(value, f"submitted choice {pair_index} value")
        if choice_id in values:
            raise ValueError("each requested choice must occur exactly once")
        values[choice_id] = value
    if len(values) != len(requested_choices):
        raise ValueError("each requested choice must occur exactly once")
    normalized = []
    for choice_id, _label, options, _initial in requested_choices:
        if choice_id not in values:
            raise ValueError("missing requested choice")
        value = values[choice_id]
        valid_values = {option_id for option_id, _option_label in options}
        if options:
            if value not in valid_values:
                raise ValueError("choice value is not an option")
        elif value not in ("true", "false"):
            raise ValueError("boolean choice value must be true or false")
        normalized.append((choice_id, value))
    return normalized


def normalize_submission(
    response_code, results_json, mode, multiple, requested_files,
    filters=(), requested_choices=()
):
    """Validate a structured picker submission against authoritative options."""
    if response_code not in (0, 1, 2):
        return 2, {}
    if response_code != 0:
        return response_code, {}
    try:
        submitted = json.loads(results_json)
        if not isinstance(submitted, dict) or set(submitted) != {
            "uris", "currentFilter", "choices"
        }:
            raise ValueError("results must use the exact structured schema")
        uris = submitted["uris"]
        if not isinstance(uris, list) or not uris:
            raise ValueError("uris must be a non-empty array")
        validate_collection_count(uris, "submitted URIs")
        paths = [_decode_local_uri(uri) for uri in uris]
        filter_index = submitted["currentFilter"]
        if type(filter_index) is not int:
            raise ValueError("currentFilter must be an integer")
        if filters:
            if filter_index < 0 or filter_index >= len(filters):
                raise ValueError("currentFilter is out of range")
            selected_filter = filters[filter_index]
            for path in paths:
                if mode == "open-dir" and os.path.isdir(path):
                    continue
                if not path_matches_filter(path, selected_filter):
                    raise ValueError("URI does not match the selected filter")
        elif filter_index != -1:
            raise ValueError("currentFilter must be -1 when no filters were requested")
        choices = _normalize_choice_submission(
            submitted["choices"], requested_choices
        )
    except (TypeError, UnicodeDecodeError, ValueError):
        return 2, {}

    if mode == "save-files":
        if [posixpath.basename(path) for path in paths] != list(requested_files or []):
            return 2, {}
        parents = [posixpath.dirname(path) for path in paths]
        if not parents or any(parent != parents[0] for parent in parents):
            return 2, {}
    elif mode == "open-file":
        if any(os.path.isdir(path) for path in paths):
            return 2, {}
        if not multiple and len(uris) > 1:
            uris = uris[:1]
    elif not multiple and len(uris) > 1:
        uris = uris[:1]
    return 0, {
        "uris": uris,
        "current_filter": filters[filter_index] if filters else None,
        "choices": choices,
    }


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


def complete_request(handle, response_code, result=None, force_exit=False):
    """Complete and clean a request once; optionally terminate its picker."""
    request = claim_request(active_requests, handle)
    if not request:
        return False
    _cleanup_claimed_request(request)
    results = {}
    if response_code == 0:
        result = result or {}
        results["uris"] = GLib.Variant("as", result.get("uris", []))
        results["choices"] = GLib.Variant("a(ss)", result.get("choices", []))
        if result.get("current_filter") is not None:
            results["current_filter"] = GLib.Variant(
                "(sa(us))", result["current_filter"]
            )
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
    del connection, interface_name, parameters
    if method_name != "Close":
        return
    if not require_frontend_sender(sender, invocation):
        return
    if not frontend_sender_matches(active_requests, object_path, sender):
        _authorization_error(invocation, "Caller did not create this request")
        return
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


def _return_invalid_options(invocation, message):
    print(f"OmaFiles FileChooser: invalid options: {message}", file=sys.stderr)
    invocation.return_value(GLib.Variant("(ua{sv})", (2, {})))


def on_filechooser_method_call(connection, sender, object_path, interface_name,
                               method_name, parameters, invocation):
    del object_path, interface_name
    if not require_frontend_sender(sender, invocation):
        return
    handle, _app_id, _parent_window, _title, options = parameters.unpack()
    if not require_new_handle(active_requests, handle, invocation):
        return
    multiple = bool(get_opt(options, "multiple", False))
    directory = bool(get_opt(options, "directory", False))

    try:
        filters, original_filters = decode_filters(get_opt(options, "filters", []))
        choices, original_choices = decode_choices(get_opt(options, "choices", []))
        if "current_filter" in options:
            current_filter = decode_current_filter(
                get_opt(options, "current_filter"), original_filters
            )
        else:
            current_filter = 0 if original_filters else -1
    except ValueError as exc:
        _return_invalid_options(invocation, str(exc))
        return

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
            _return_invalid_options(invocation, f"SaveFiles names: {exc}")
            return
    elif method_name == "SaveFile":
        mode = "save-file"
    elif directory:
        mode = "open-dir"
    else:
        mode = "open-file"

    try:
        payload = build_picker_payload(
            folder=folder_path,
            request_id=handle,
            mode=mode,
            multiple=multiple,
            suggested_name=suggested_name,
            files=files,
            filters=filters,
            current_filter=current_filter,
            choices=choices,
        )
    except (TypeError, ValueError) as exc:
        _return_invalid_options(invocation, str(exc))
        return

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
        "filters": original_filters,
        "choices": original_choices,
        "token": token,
        "frontend_sender": sender,
        "picker_sender": None,
        "process": None,
    }

    def on_proc_finished(process, result, request_handle):
        try:
            process.wait_finish(result)
        except GLib.Error:
            pass
        complete_request(request_handle, 1)

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
    response_code, result = normalize_submission(
        response_code,
        results_json,
        request["mode"],
        request["multiple"],
        request["files"],
        request["filters"],
        request["choices"],
    )
    if not complete_request(request_id, response_code, result):
        _invalid_request(invocation)
        return
    invocation.return_value(None)


def on_bus_acquired(connection, name):
    del name
    global dbus_connection, frontend_owner
    dbus_connection = connection
    connection.signal_subscribe(
        "org.freedesktop.DBus",
        "org.freedesktop.DBus",
        "NameOwnerChanged",
        "/org/freedesktop/DBus",
        FRONTEND_BUS_NAME,
        0,
        on_frontend_owner_changed,
        None,
    )
    try:
        frontend_owner = resolve_frontend_owner(connection)
    except GLib.Error:
        frontend_owner = ""
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

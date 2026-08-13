#!/usr/bin/python3
# org.freedesktop.impl.portal.FileChooser backend for Omafiles.

import sys
import json
from pathlib import Path

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

BUS_NAME = "org.freedesktop.impl.portal.desktop.omafiles"
OBJECT_PATH = "/org/freedesktop/portal/desktop"
OMAFILES_BIN = str(Path.home() / ".local" / "bin" / "omafiles")

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

loop = GLib.MainLoop()
dbus_connection = None
active_requests = {}

def get_opt(options, key, default=None):
    if key not in options:
        return default
    val = options[key]
    if hasattr(val, 'unpack'):
        return val.unpack()
    return val

def cleanup_request(handle):
    req = active_requests.pop(handle, None)
    if req:
        try:
            dbus_connection.unregister_object(req['registration_id'])
        except Exception as e:
            print(f"omafiles FileChooser: failed to unregister request object at {handle}: {e}", file=sys.stderr)

def request_method_call(connection, sender, object_path, interface_name, method_name, parameters, invocation):
    if method_name == "Close":
        req = active_requests.get(object_path)
        if req:
            # responseCode 1 = cancelled
            req['invocation'].return_value(GLib.Variant('(ua{sv})', (1, {})))
            cleanup_request(object_path)
        invocation.return_value(None)

def on_filechooser_method_call(connection, sender, object_path, interface_name, method_name, parameters, invocation):
    args = parameters.unpack()
    handle, app_id, parent_window, title, options = args

    # Extract options safely
    multiple = get_opt(options, 'multiple', False)
    directory = get_opt(options, 'directory', False)
    
    # current_folder is ay (array of bytes)
    current_folder_bytes = get_opt(options, 'current_folder', b'')
    folder_path = ""
    if current_folder_bytes:
        try:
            folder_path = current_folder_bytes.decode('utf-8').rstrip('\x00')
        except Exception:
            pass

    # Fallback to home if path not found or empty
    if not folder_path or not Path(folder_path).exists():
        folder_path = str(Path.home())

    suggested_name = get_opt(options, 'current_name', '')
    if not suggested_name:
        # Check current_file ay option
        current_file_bytes = get_opt(options, 'current_file', b'')
        if current_file_bytes:
            try:
                cf = Path(current_file_bytes.decode('utf-8').rstrip('\x00'))
                suggested_name = cf.name
                if not folder_path:
                    folder_path = str(cf.parent)
            except Exception:
                pass

    # Resolve picker mode
    mode = "open-file"
    if directory:
        mode = "open-dir"
    elif method_name == "SaveFile":
        mode = "save-file"
    elif method_name == "SaveFiles":
        mode = "open-dir" # SaveFiles selects a directory to save multiple files

    multiple_str = "true" if multiple else "false"
    suggested_name_str = suggested_name.replace('\n', '').replace('\r', '') if suggested_name else ""

    # Register the Request object at the handle path
    request_node = Gio.DBusNodeInfo.new_for_xml(REQUEST_INTROSPECTION_XML)
    registration_id = connection.register_object(
        handle,
        request_node.interfaces[0],
        request_method_call,
        None,
        None,
    )

    # Store request
    active_requests[handle] = {
        'invocation': invocation,
        'registration_id': registration_id,
        'multiple': multiple,
    }

    def on_proc_finished(proc, result, req_handle):
        try:
            proc.wait_finish(result)
        except Exception:
            pass
        req = active_requests.get(req_handle)
        if req:
            # Process exited without submitting a response (e.g. window closed or killed) -> Cancel (1)
            req['invocation'].return_value(GLib.Variant('(ua{sv})', (1, {})))
            cleanup_request(req_handle)

    # Summon Omafiles (single instance)
    payload = f"{folder_path}\npicker:{handle}:{mode}:{multiple_str}:{suggested_name_str}"
    try:
        proc = Gio.Subprocess.new([OMAFILES_BIN, payload], Gio.SubprocessFlags.NONE)
        proc.wait_async(None, on_proc_finished, handle)
    except GLib.Error as e:
        print(f"omafiles FileChooser: failed to launch omafiles: {e}", file=sys.stderr)
        # Return error/other code 2
        invocation.return_value(GLib.Variant('(ua{sv})', (2, {})))
        cleanup_request(handle)

def on_submission_method_call(connection, sender, object_path, interface_name, method_name, parameters, invocation):
    if method_name == "SubmitResponse":
        request_id, response_code, results_json = parameters.unpack()
        req = active_requests.pop(request_id, None)
        if req:
            try:
                dbus_connection.unregister_object(req['registration_id'])
            except Exception:
                pass

            try:
                uris = json.loads(results_json)
            except Exception:
                uris = []

            # Strict single-selection guarantee when multiple is False
            if not req.get('multiple', False) and len(uris) > 1:
                uris = [uris[0]]

            results = {
                'uris': GLib.Variant('as', uris)
            }
            req['invocation'].return_value(GLib.Variant('(ua{sv})', (response_code, results)))
        invocation.return_value(None)

def on_bus_acquired(connection, name):
    global dbus_connection
    dbus_connection = connection

    node_info = Gio.DBusNodeInfo.new_for_xml(INTROSPECTION_XML)
    
    # Register org.freedesktop.impl.portal.FileChooser
    connection.register_object(
        OBJECT_PATH,
        node_info.interfaces[0],
        on_filechooser_method_call,
        None,
        None,
    )

    # Register custom submission interface
    connection.register_object(
        OBJECT_PATH,
        node_info.interfaces[1],
        on_submission_method_call,
        None,
        None,
    )

def on_name_lost(connection, name):
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

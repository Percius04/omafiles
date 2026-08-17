#!/usr/bin/env python3
"""Pure unit tests for the OmaFiles FileChooser portal helpers."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "dbus-filechooser.py"
spec = importlib.util.spec_from_file_location("omafiles_filechooser", MODULE_PATH)
chooser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chooser)


class SaveFilesDecodingTests(unittest.TestCase):
    def test_decodes_ordered_nul_terminated_basenames(self):
        raw = [b"second file.txt\0", bytearray("first-π.txt\0", "utf-8")]
        self.assertEqual(
            chooser.decode_save_files(raw),
            ["second file.txt", "first-π.txt"],
        )

    def test_rejects_invalid_names_and_encoding(self):
        invalid = [
            [b"missing-nul"],
            [b"nested/name\0"],
            [b".\0"],
            [b"..\0"],
            [b"embedded\0nul\0"],
            [b"\xff\0"],
        ]
        for raw in invalid:
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError):
                    chooser.decode_save_files(raw)


class PickerPayloadTests(unittest.TestCase):
    def test_json_payload_has_no_secret_and_preserves_order(self):
        payload = chooser.build_picker_payload(
            folder="/tmp/a:b\nreserved #?%",
            request_id="/org/freedesktop/portal/desktop/request/1_2/test",
            mode="save-files",
            multiple=False,
            suggested_name="",
            files=["two:2.txt", "one 1.txt"],
        )
        decoded = json.loads(payload)
        self.assertEqual(decoded["kind"], "picker")
        self.assertEqual(decoded["folder"], "/tmp/a:b\nreserved #?%")
        self.assertEqual(decoded["files"], ["two:2.txt", "one 1.txt"])
        self.assertNotIn("token", decoded)
        self.assertNotIn("secret", payload.lower())
        self.assertNotIn("picker:", payload)


class FrontendAuthorizationTests(unittest.TestCase):
    class FakeInvocation:
        def __init__(self):
            self.errors = []
            self.replies = []

        def return_dbus_error(self, name, message):
            self.errors.append((name, message))

        def return_value(self, value):
            self.replies.append(value)

    def setUp(self):
        self.original_owner = chooser.frontend_owner
        chooser.frontend_owner = ":1.20"

    def tearDown(self):
        chooser.frontend_owner = self.original_owner

    def test_authorized_and_unauthorized_frontend_requests(self):
        authorized = self.FakeInvocation()
        unauthorized = self.FakeInvocation()
        self.assertTrue(chooser.require_frontend_sender(":1.20", authorized))
        self.assertFalse(chooser.require_frontend_sender(":1.99", unauthorized))
        self.assertEqual(authorized.errors, [])
        self.assertEqual(len(unauthorized.errors), 1)

    def test_duplicate_handle_is_rejected_before_registration(self):
        invocation = self.FakeInvocation()
        requests = {"/request/active": {"frontend_sender": ":1.20"}}
        self.assertFalse(
            chooser.require_new_handle(requests, "/request/active", invocation)
        )
        self.assertEqual(len(invocation.errors), 1)

    def test_close_accepts_only_current_stored_frontend_sender(self):
        requests = {"/request/active": {"frontend_sender": ":1.20"}}
        self.assertTrue(
            chooser.frontend_sender_matches(requests, "/request/active", ":1.20")
        )
        self.assertFalse(
            chooser.frontend_sender_matches(requests, "/request/active", ":1.99")
        )

        invocation = self.FakeInvocation()
        original_requests = chooser.active_requests
        original_complete = chooser.complete_request
        try:
            chooser.active_requests = requests
            chooser.frontend_owner = ":1.99"
            chooser.complete_request = lambda *args, **kwargs: self.fail(
                "stale frontend sender completed the request"
            )
            chooser.request_method_call(
                object(), ":1.20", "/request/active", "unused", "Close", (),
                invocation,
            )
            self.assertEqual(len(invocation.errors), 1)
            self.assertEqual(invocation.replies, [])
        finally:
            chooser.active_requests = original_requests
            chooser.complete_request = original_complete
            chooser.frontend_owner = ":1.20"

    def test_owner_resolution_uses_session_bus_connection(self):
        class FakeReply:
            def unpack(self):
                return (":1.20",)

        class FakeConnection:
            def __init__(self):
                self.calls = []

            def call_sync(self, *args):
                self.calls.append(args)
                return FakeReply()

        class FakeVariant:
            def __init__(self, signature, value):
                self.signature = signature
                self.value = value

        class FakeVariantType:
            @staticmethod
            def new(signature):
                return signature

        class FakeGLib:
            Variant = FakeVariant
            VariantType = FakeVariantType

        original_glib = chooser.GLib
        try:
            chooser.GLib = FakeGLib
            connection = FakeConnection()
            self.assertEqual(chooser.resolve_frontend_owner(connection), ":1.20")
            self.assertEqual(len(connection.calls), 1)
            self.assertEqual(connection.calls[0][0], "org.freedesktop.DBus")
        finally:
            chooser.GLib = original_glib

    def test_owner_loss_cleanup_returns_only_matching_requests(self):
        requests = {
            "/request/a": {"frontend_sender": ":1.20"},
            "/request/b": {"frontend_sender": ":1.99"},
        }
        self.assertEqual(
            chooser.frontend_request_handles(requests, ":1.20"), ["/request/a"]
        )

    def test_owner_loss_callback_cleans_matching_requests(self):
        class FakeParameters:
            def unpack(self):
                return ("org.freedesktop.portal.Desktop", ":1.20", "")

        completed = []
        original_requests = chooser.active_requests
        original_complete = chooser.complete_request
        try:
            chooser.active_requests = {
                "/request/a": {"frontend_sender": ":1.20"},
                "/request/b": {"frontend_sender": ":1.99"},
            }
            chooser.complete_request = lambda handle, code, force_exit=False: completed.append(
                (handle, code, force_exit)
            )
            chooser.on_frontend_owner_changed(
                object(), ":1.0", "/org/freedesktop/DBus",
                "org.freedesktop.DBus", "NameOwnerChanged", FakeParameters()
            )
            self.assertEqual(completed, [("/request/a", 1, True)])
            self.assertEqual(chooser.frontend_owner, "")
        finally:
            chooser.active_requests = original_requests
            chooser.complete_request = original_complete


class SubmissionNormalizationTests(unittest.TestCase):
    def test_backend_exports_the_impl_request_close_interface(self):
        self.assertIn(
            'interface name="org.freedesktop.impl.portal.Request"',
            chooser.REQUEST_INTROSPECTION_XML,
        )
        self.assertNotIn(
            'interface name="org.freedesktop.portal.Request"',
            chooser.REQUEST_INTROSPECTION_XML,
        )

    def test_submission_sender_must_match_registered_picker(self):
        requests = {"/request/active": {"picker_sender": ":1.42"}}
        self.assertTrue(
            chooser.sender_matches_request(requests, "/request/active", ":1.42")
        )
        self.assertFalse(
            chooser.sender_matches_request(requests, "/request/active", ":1.99")
        )
        self.assertFalse(
            chooser.sender_matches_request(requests, "/request/completed", ":1.42")
        )

    def test_claim_request_is_idempotent(self):
        requests = {"/request/active": {"value": 1}}
        self.assertEqual(chooser.claim_request(requests, "/request/active"), {"value": 1})
        self.assertIsNone(chooser.claim_request(requests, "/request/active"))

    def test_close_completes_once_and_force_exits_retained_process(self):
        class FakeVariant:
            def __init__(self, signature, value):
                self.signature = signature
                self.value = value

        class FakeGLib:
            Variant = FakeVariant

        class FakeInvocation:
            def __init__(self):
                self.replies = []

            def return_value(self, value):
                self.replies.append(value)

        class FakeProcess:
            def __init__(self):
                self.force_exit_calls = 0

            def force_exit(self):
                self.force_exit_calls += 1

        invocation = FakeInvocation()
        process = FakeProcess()
        original_glib = chooser.GLib
        original_connection = chooser.dbus_connection
        original_requests = chooser.active_requests
        try:
            chooser.GLib = FakeGLib
            chooser.dbus_connection = None
            chooser.active_requests = {
                "/request/active": {
                    "invocation": invocation,
                    "registration_id": 7,
                    "process": process,
                }
            }
            self.assertTrue(
                chooser.complete_request("/request/active", 1, force_exit=True)
            )
            self.assertFalse(
                chooser.complete_request("/request/active", 1, force_exit=True)
            )
            self.assertEqual(len(invocation.replies), 1)
            self.assertEqual(process.force_exit_calls, 1)
        finally:
            chooser.GLib = original_glib
            chooser.dbus_connection = original_connection
            chooser.active_requests = original_requests

    def test_open_file_single_selection_is_truncated(self):
        code, uris = chooser.normalize_submission(
            0, '["file:///one", "file:///two"]', "open-file", False, []
        )
        self.assertEqual((code, uris), (0, ["file:///one"]))

    def test_open_file_rejects_a_directory_result(self):
        with tempfile.TemporaryDirectory() as directory:
            uri = Path(directory).as_uri()
            self.assertEqual(
                chooser.normalize_submission(
                    0, json.dumps([uri]), "open-file", False, []
                ),
                (2, []),
            )

    def test_save_files_requires_exact_names_order_and_common_folder(self):
        requested = ["two #.txt", "one π.txt"]
        valid = '["file:///dest/two%20%23.txt", "file:///dest/one%20%CF%80.txt"]'
        self.assertEqual(
            chooser.normalize_submission(0, valid, "save-files", False, requested),
            (0, ["file:///dest/two%20%23.txt", "file:///dest/one%20%CF%80.txt"]),
        )
        invalid_results = [
            '["file:///dest/one%20%CF%80.txt", "file:///dest/two%20%23.txt"]',
            '["file:///dest/two%20%23.txt", "file:///other/one%20%CF%80.txt"]',
            '["file://remote/dest/two%20%23.txt", "file://remote/dest/one%20%CF%80.txt"]',
            '["file:///dest/../two%20%23.txt", "file:///dest/one%20%CF%80.txt"]',
            '["file:///dest/two%ZZ%23.txt", "file:///dest/one%20%CF%80.txt"]',
            '["file:///dest/two%FF.txt", "file:///dest/one%20%CF%80.txt"]',
        ]
        for result in invalid_results:
            with self.subTest(result=result):
                self.assertEqual(
                    chooser.normalize_submission(
                        0, result, "save-files", False, requested
                    ),
                    (2, []),
                )

    def test_cancel_has_no_results_and_malformed_success_is_error(self):
        self.assertEqual(
            chooser.normalize_submission(
                1, '["file:///ignored"]', "open-file", True, []
            ),
            (1, []),
        )
        self.assertEqual(
            chooser.normalize_submission(0, '{"not":"a list"}', "open-file", True, []),
            (2, []),
        )
        self.assertEqual(
            chooser.normalize_submission(99, "[]", "open-file", True, []),
            (2, []),
        )


if __name__ == "__main__":
    unittest.main()

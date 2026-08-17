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


class PickerContractDecodingTests(unittest.TestCase):
    VALID_FILTERS = [
        ("Text", [(0, "*.txt"), (1, "text/plain")]),
        ("Images", [(1, "image/*")]),
    ]
    VALID_CHOICES = [
        ("encoding", "Encoding", [("utf8", "UTF-8"), ("latin1", "Latin-1")], "utf8"),
        ("readonly", "Read only", [], "false"),
    ]

    def test_decodes_filters_current_filter_and_choices(self):
        filters, originals = chooser.decode_filters(self.VALID_FILTERS)
        choices, choice_originals = chooser.decode_choices(self.VALID_CHOICES)
        self.assertEqual(filters[0]["rules"][1], {"type": 1, "value": "text/plain"})
        self.assertEqual(chooser.decode_current_filter(self.VALID_FILTERS[1], originals), 1)
        self.assertEqual(choices[0]["selected"], "utf8")
        self.assertEqual(originals[0], ("Text", ((0, "*.txt"), (1, "text/plain"))))
        self.assertEqual(choice_originals[1], ("readonly", "Read only", (), "false"))

    def test_rejects_malformed_filters(self):
        malformed = [
            "not-an-array",
            [("", [(0, "*.txt")])],
            [("Text", [])],
            [("Text", [(2, "*.txt")])],
            [("Text", [(True, "*.txt")])],
            [("Text", [(0, "")])],
            [("Text", [(1, "not a mime")])],
            [("Text\0", [(0, "*.txt")])],
            [("Text", [(0, "\ud800")])],
        ]
        for value in malformed:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    chooser.decode_filters(value)

    def test_rejects_missing_or_unknown_current_filter(self):
        _, originals = chooser.decode_filters(self.VALID_FILTERS)
        for value in [("Other", [(0, "*.other")]), ("Text", [(0, "*.txt")])]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    chooser.decode_current_filter(value, originals)
        with self.assertRaises(ValueError):
            chooser.decode_current_filter(self.VALID_FILTERS[0], [])

    def test_rejects_malformed_choices(self):
        malformed = [
            "not-an-array",
            [("", "Label", [], "false")],
            [("dup", "One", [], "false"), ("dup", "Two", [], "true")],
            [("choice", "", [("a", "A")], "a")],
            [("choice", "Label", [("", "A")], "")],
            [("choice", "Label", [("a", "A"), ("a", "Again")], "a")],
            [("choice", "Label", [("a", "A")], "missing")],
            [("toggle", "Toggle", [], "maybe")],
            [("bad\0", "Label", [], "false")],
            [("bad", "\ud800", [], "false")],
        ]
        for value in malformed:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    chooser.decode_choices(value)

    def test_size_and_count_bounds_are_tied_to_linux_argument_limit(self):
        too_long = "x" * (chooser.MAX_PICKER_ARGUMENT_BYTES + 1)
        with self.assertRaises(ValueError):
            chooser.decode_filters([("Text", [(0, too_long)])])
        with self.assertRaises(ValueError):
            chooser.decode_choices([("choice", "Choice", [(too_long, "X")], too_long)])
        with self.assertRaises(ValueError):
            chooser.validate_collection_count(
                range(chooser.MAX_PICKER_COLLECTION_ITEMS + 1), "test collection"
            )


class PickerPayloadTests(unittest.TestCase):
    def test_json_payload_has_no_secret_and_preserves_contract(self):
        payload = chooser.build_picker_payload(
            folder="/tmp/a:b\nreserved #?%",
            request_id="/org/freedesktop/portal/desktop/request/1_2/test",
            mode="save-files",
            multiple=False,
            suggested_name="",
            files=["two:2.txt", "one 1.txt"],
            filters=[{"name": "Text", "rules": [{"type": 0, "value": "*.txt"}]}],
            current_filter=0,
            choices=[{"id": "encoding", "label": "Encoding", "options": [{"id": "utf8", "label": "UTF-8"}], "selected": "utf8"}],
        )
        decoded = json.loads(payload)
        self.assertEqual(decoded["kind"], "picker")
        self.assertEqual(decoded["folder"], "/tmp/a:b\nreserved #?%")
        self.assertEqual(decoded["files"], ["two:2.txt", "one 1.txt"])
        self.assertEqual(decoded["currentFilter"], 0)
        self.assertEqual(decoded["filters"][0]["name"], "Text")
        self.assertEqual(decoded["choices"][0]["selected"], "utf8")
        self.assertNotIn("token", decoded)
        self.assertNotIn("secret", payload.lower())
        self.assertNotIn("picker:", payload)

    def test_rejects_payload_over_linux_single_argument_limit(self):
        with self.assertRaises(ValueError):
            chooser.build_picker_payload(
                folder="/tmp",
                request_id="/request/test",
                mode="open-file",
                multiple=False,
                suggested_name="",
                files=[],
                filters=[{"name": "X", "rules": [{"type": 0, "value": "x" * chooser.MAX_PICKER_ARGUMENT_BYTES}]}],
                current_filter=0,
                choices=[],
            )


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

    @staticmethod
    def submission(uris, current_filter=-1, choices=None):
        return json.dumps(
            {"uris": uris, "currentFilter": current_filter, "choices": choices or []},
            ensure_ascii=False,
        )

    def test_malformed_options_return_response_two(self):
        class FakeVariant:
            def __init__(self, signature, value):
                self.signature = signature
                self.value = value

        class FakeGLib:
            Variant = FakeVariant

        invocation = FrontendAuthorizationTests.FakeInvocation()
        original_glib = chooser.GLib
        try:
            chooser.GLib = FakeGLib
            chooser._return_invalid_options(invocation, "bad filters")
            self.assertEqual(len(invocation.replies), 1)
            self.assertEqual(invocation.replies[0].signature, "(ua{sv})")
            self.assertEqual(invocation.replies[0].value, (2, {}))
        finally:
            chooser.GLib = original_glib

    def test_success_returns_exact_current_filter_and_choice_variant_types(self):
        class FakeVariant:
            def __init__(self, signature, value):
                self.signature = signature
                self.value = value

        class FakeGLib:
            Variant = FakeVariant

        invocation = FrontendAuthorizationTests.FakeInvocation()
        result = {
            "uris": ["file:///tmp/note.txt"],
            "current_filter": ("Text", ((0, "*.txt"),)),
            "choices": [("encoding", "utf8")],
        }
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
                    "process": None,
                }
            }
            self.assertTrue(chooser.complete_request("/request/active", 0, result))
            outer = invocation.replies[0]
            self.assertEqual(outer.signature, "(ua{sv})")
            variants = outer.value[1]
            self.assertEqual(variants["uris"].signature, "as")
            self.assertEqual(variants["current_filter"].signature, "(sa(us))")
            self.assertEqual(variants["current_filter"].value, result["current_filter"])
            self.assertEqual(variants["choices"].signature, "a(ss)")
            self.assertEqual(variants["choices"].value, result["choices"])
        finally:
            chooser.GLib = original_glib
            chooser.dbus_connection = original_connection
            chooser.active_requests = original_requests

    def test_open_file_single_selection_is_truncated(self):
        code, result = chooser.normalize_submission(
            0, self.submission(["file:///one", "file:///two"]),
            "open-file", False, []
        )
        self.assertEqual(code, 0)
        self.assertEqual(result["uris"], ["file:///one"])

    def test_open_file_rejects_a_directory_result(self):
        with tempfile.TemporaryDirectory() as directory:
            uri = Path(directory).as_uri()
            self.assertEqual(
                chooser.normalize_submission(
                    0, self.submission([uri]), "open-file", False, []
                ),
                (2, {}),
            )

    def test_save_files_requires_exact_names_order_and_common_folder(self):
        requested = ["two #.txt", "one π.txt"]
        valid_uris = ["file:///dest/two%20%23.txt", "file:///dest/one%20%CF%80.txt"]
        code, result = chooser.normalize_submission(
            0, self.submission(valid_uris), "save-files", False, requested
        )
        self.assertEqual(code, 0)
        self.assertEqual(result["uris"], valid_uris)
        invalid_results = [
            ["file:///dest/one%20%CF%80.txt", "file:///dest/two%20%23.txt"],
            ["file:///dest/two%20%23.txt", "file:///other/one%20%CF%80.txt"],
            ["file://remote/dest/two%20%23.txt", "file://remote/dest/one%20%CF%80.txt"],
            ["file:///dest/../two%20%23.txt", "file:///dest/one%20%CF%80.txt"],
            ["file:///dest/two%ZZ%23.txt", "file:///dest/one%20%CF%80.txt"],
            ["file:///dest/two%FF.txt", "file:///dest/one%20%CF%80.txt"],
        ]
        for uris in invalid_results:
            with self.subTest(uris=uris):
                self.assertEqual(
                    chooser.normalize_submission(
                        0, self.submission(uris), "save-files", False, requested
                    ),
                    (2, {}),
                )

    def test_glob_and_mime_filters_accept_and_reject(self):
        filters = [
            ("Text glob", ((0, "*.txt"),)),
            ("PNG MIME", ((1, "image/png"),)),
        ]
        valid_cases = [
            ("file:///tmp/note.txt", 0),
            ("file:///tmp/image.png", 1),
        ]
        for uri, index in valid_cases:
            with self.subTest(uri=uri, index=index):
                code, result = chooser.normalize_submission(
                    0, self.submission([uri], index), "save-file", False, [], filters
                )
                self.assertEqual(code, 0)
                self.assertEqual(result["current_filter"], filters[index])
        for uri, index in [("file:///tmp/note.md", 0), ("file:///tmp/image.jpg", 1)]:
            with self.subTest(uri=uri, index=index):
                self.assertEqual(
                    chooser.normalize_submission(
                        0, self.submission([uri], index), "save-file", False, [], filters
                    ),
                    (2, {}),
                )

    def test_directory_mode_exempts_directories_from_filter(self):
        filters = [("Text", ((0, "*.txt"),))]
        with tempfile.TemporaryDirectory() as directory:
            code, result = chooser.normalize_submission(
                0, self.submission([Path(directory).as_uri()], 0),
                "open-dir", False, [], filters
            )
            self.assertEqual(code, 0)
            self.assertEqual(result["current_filter"], filters[0])

    def test_exact_choice_results_are_required_and_normalized(self):
        choices = [
            ("encoding", "Encoding", (("utf8", "UTF-8"), ("latin1", "Latin-1")), "utf8"),
            ("readonly", "Read only", (), "false"),
        ]
        submitted = [["readonly", "true"], ["encoding", "latin1"]]
        code, result = chooser.normalize_submission(
            0, self.submission(["file:///tmp/note.txt"], -1, submitted),
            "save-file", False, [], (), choices
        )
        self.assertEqual(code, 0)
        self.assertEqual(result["choices"], [("encoding", "latin1"), ("readonly", "true")])
        invalid = [
            [],
            [["encoding", "utf8"]],
            [["encoding", "missing"], ["readonly", "false"]],
            [["encoding", "utf8"], ["readonly", "maybe"]],
            [["encoding", "utf8"], ["encoding", "latin1"], ["readonly", "false"]],
            [["encoding", "utf8"], ["readonly", "false"], ["extra", "x"]],
        ]
        for submitted_choices in invalid:
            with self.subTest(choices=submitted_choices):
                self.assertEqual(
                    chooser.normalize_submission(
                        0, self.submission(["file:///tmp/note.txt"], -1, submitted_choices),
                        "save-file", False, [], (), choices
                    ),
                    (2, {}),
                )

    def test_cancel_has_no_results_and_malformed_success_is_error(self):
        self.assertEqual(
            chooser.normalize_submission(
                1, self.submission(["file:///ignored"]), "open-file", True, []
            ),
            (1, {}),
        )
        malformed = [
            '{"not":"the schema"}',
            '["file:///tmp/file"]',
            '{"uris":["file:///tmp/file"],"currentFilter":-1,"choices":[],"extra":true}',
        ]
        for value in malformed:
            self.assertEqual(
                chooser.normalize_submission(0, value, "open-file", True, []),
                (2, {}),
            )
        self.assertEqual(
            chooser.normalize_submission(99, "{}", "open-file", True, []),
            (2, {}),
        )


if __name__ == "__main__":
    unittest.main()

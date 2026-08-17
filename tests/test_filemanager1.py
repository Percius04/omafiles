#!/usr/bin/env python3
"""Pure tests for org.freedesktop.FileManager1 payload construction."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "dbus-filemanager1.py"
spec = importlib.util.spec_from_file_location("omafiles_filemanager1", MODULE_PATH)
filemanager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(filemanager)


class FileManagerPayloadTests(unittest.TestCase):
    def test_build_payload_has_strict_non_secret_schema(self):
        payload = filemanager.build_file_manager_payload(
            "show-properties", "/tmp/folder", ["a.txt", "b π.txt"]
        )
        decoded = json.loads(payload)
        self.assertEqual(
            decoded,
            {
                "kind": "file-manager",
                "action": "show-properties",
                "folder": "/tmp/folder",
                "basenames": ["a.txt", "b π.txt"],
            },
        )
        self.assertNotIn("secret", payload.lower())
        self.assertNotIn("token", payload.lower())

    def test_rejects_invalid_action_folder_and_basenames(self):
        invalid = [
            ("unknown", "/tmp", []),
            ("show-items", "relative", ["a"]),
            ("show-items", "/tmp", ["../a"]),
            ("show-items", "/tmp", [""]),
            ("show-items", "/tmp", ["a/b"]),
        ]
        for action, folder, basenames in invalid:
            with self.subTest(action=action, folder=folder, basenames=basenames):
                with self.assertRaises(ValueError):
                    filemanager.build_file_manager_payload(action, folder, basenames)

    def test_show_items_and_properties_use_distinct_actions(self):
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.txt"
            second = Path(directory) / "second.txt"
            first.write_text("one", encoding="utf-8")
            second.write_text("two", encoding="utf-8")
            uris = [first.as_uri(), second.as_uri()]
            items = [json.loads(value) for value in filemanager.payloads_for_uris(uris, "show-items")]
            properties = [
                json.loads(value)
                for value in filemanager.payloads_for_uris(uris, "show-properties")
            ]
            self.assertEqual(len(items), 1)
            self.assertEqual(items[0]["action"], "show-items")
            self.assertEqual(properties[0]["action"], "show-properties")
            self.assertEqual(items[0]["basenames"], ["first.txt", "second.txt"])
            self.assertEqual(properties[0]["basenames"], items[0]["basenames"])

    def test_show_folders_sends_each_unique_absolute_folder_without_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            child = Path(directory) / "child"
            child.mkdir()
            payloads = [
                json.loads(value)
                for value in filemanager.payloads_for_uris(
                    [child.as_uri(), child.as_uri()], "show-folders"
                )
            ]
            self.assertEqual(
                payloads,
                [{"kind": "file-manager", "action": "show-folders",
                  "folder": str(child), "basenames": []}],
            )


if __name__ == "__main__":
    unittest.main()

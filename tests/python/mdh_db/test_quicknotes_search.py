import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "40_scripts" / "py_scripts"))

from mdh_db.quicknotes_search import _inspect, _snapshot, search_quicknotes
from test_aggregate import volume_alias


class QuickNotesSearchTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name) / "外部 notes O'Brien"
        self.root.mkdir()

    def write(self, name, raw):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return path

    def test_hard_link_to_file_outside_root_is_searchable(self):
        outside = self.root.parent / "outside.md"
        raw = b"Shared Markdown text\n"
        outside.write_bytes(raw)
        alias = self.root / "inside.md"
        os.link(outside, alias)
        self.assertGreater(alias.stat().st_nlink, 1)

        result = search_quicknotes(self.root, "Markdown")

        self.assertEqual((result["files_scanned"], result["files_matched"]), (1, 1))
        self.assertFalse(result["incomplete"])
        self.assertEqual(result["diagnostics"], [])
        self.assertEqual([hit["path"] for hit in result["hits"]], ["inside.md"])
        self.assertEqual(result["hits"][0]["snapshot_hash"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(outside.read_bytes(), raw)

    def test_file_and_scope_of_terms_with_exact_snapshot_positions(self):
        raw = b"\xef\xbb\xbf" + "---\r\n📚 kind: SQL\r---\nSQL sql\n```\nindex\n```".encode()
        first = self.write("A/same.MD", raw)
        self.write("B/same.md", b"SQL index")
        self.write("sql index.md", b"filename only")
        self.write("sql-only.md", b"SQL")
        self.write("index-only.md", b"index")
        self.write("empty.md", b"")
        self.write("not-markdown.txt", b"SQL index")

        result = search_quicknotes(self.root, " sql sql　index ")
        self.assertEqual((result["files_scanned"], result["files_matched"], result["matching_lines"]), (6, 2, 4))
        self.assertEqual([hit["path"] for hit in result["hits"]], ["A/same.MD", "B/same.md"])
        hit = result["hits"][0]
        self.assertEqual(hit["snapshot_hash"], hashlib.sha256(raw).hexdigest())
        self.assertEqual((hit["kind"], hit["source"]), ("file", "QuickNotes"))
        self.assertNotIn("day", hit)
        self.assertEqual([(m["line"], m["column"], m["excerpt"]) for m in hit["matches"]],
                         [(2, 9, "SQL"), (4, 1, "SQL"), (6, 1, "index")])
        source = raw.decode("utf-8-sig")
        for match in hit["matches"]:
            self.assertEqual(source[match["start"]:match["stop"]], match["excerpt"])
        self.assertEqual(hit["lines"][0]["text"], "📚 kind: SQL")
        self.assertEqual(first.read_bytes(), raw)

    def test_literal_unicode_queries_and_fresh_content(self):
        path = self.write("note.md", "Ä sql 日本語 %_\\ 👩‍🏫".encode())
        for query, count in (("ä", 0), ("SQL 日本", 1), ("%_\\ 👩‍🏫", 1), ("", 0), ("   ", 0)):
            with self.subTest(query=query):
                self.assertEqual(search_quicknotes(self.root, query)["files_matched"], count)
        with self.assertRaisesRegex(ValueError, "NUL"):
            search_quicknotes(self.root, "\x00")
        path.write_bytes(b"new contents")
        self.assertEqual(search_quicknotes(self.root, "SQL")["files_matched"], 0)
        self.assertEqual(search_quicknotes(self.root, "new")["files_matched"], 1)

    def test_empty_missing_invalid_utf8_and_read_failures_are_distinct(self):
        result = search_quicknotes(self.root, "good")
        self.assertEqual((result["files_scanned"], result["incomplete"]), (0, False))
        with self.assertRaises(FileNotFoundError):
            search_quicknotes(self.root / "missing", "good")
        self.write("valid.md", b"good")
        self.write("invalid.md", b"\xff")
        unreadable = self.write("unreadable.md", b"good")
        self.write("private/inside.md", b"good")
        scan = os.scandir

        def read(path, info, chain):
            if path == unreadable:
                raise PermissionError("injected read failure")
            return _snapshot(path, info, chain)

        def scandir(directory):
            if directory == self.root / "private":
                raise PermissionError("injected directory failure")
            return scan(directory)

        with patch("mdh_db.quicknotes_search._snapshot", side_effect=read), \
                patch("mdh_db.quicknotes_search.os.scandir", side_effect=scandir):
            result = search_quicknotes(self.root, "good")
        self.assertTrue(result["incomplete"])
        self.assertEqual(result["files_scanned"], 1)
        self.assertEqual([d["code"] for d in result["diagnostics"]],
                         ["FILE_READ_FAILED", "DIRECTORY_READ_FAILED", "FILE_READ_FAILED"])

    def test_changed_file_is_not_returned_as_a_complete_snapshot(self):
        path = self.write("changed.md", b"original")

        def change(file, info, chain):
            path.write_bytes(b"replacement")
            return _snapshot(file, info, chain)

        with patch("mdh_db.quicknotes_search._snapshot", side_effect=change):
            result = search_quicknotes(self.root, "original")
        self.assertTrue(result["incomplete"])
        self.assertFalse(result["hits"])
        self.assertEqual(result["files_scanned"], 0)
        self.assertEqual(result["diagnostics"][0]["code"], "FILE_READ_FAILED")

    def test_file_without_inode_is_searchable(self):
        bad = self.write("bad.md", b"word")
        self.write("good.md", b"word")
        bad_info = bad.stat()
        fstat = os.fstat

        def without_inode(info):
            return os.stat_result((*info[:1], 0, *info[2:]))

        def inspect(path):
            info, linked = _inspect(path)
            return (without_inode(info) if path == bad else info), linked

        def opened_info(fd):
            info = fstat(fd)
            if (info.st_dev, info.st_ino) == (bad_info.st_dev, bad_info.st_ino):
                return without_inode(info)
            return info

        with patch("mdh_db.quicknotes_search._inspect", side_effect=inspect), patch.object(
                os, "fstat", side_effect=opened_info):
            result = search_quicknotes(self.root, "word")
        self.assertFalse(result["incomplete"])
        self.assertEqual([hit["path"] for hit in result["hits"]], ["bad.md", "good.md"])
        self.assertEqual(result["diagnostics"], [])

    def test_uninspectable_file_keeps_other_hits(self):
        failed = self.write("bad.md", b"word")
        self.write("good.md", b"word")
        lstat = Path.lstat

        def inspect_stat(path):
            if path == failed:
                raise FileNotFoundError(path)
            return lstat(path)

        with patch.object(Path, "lstat", inspect_stat):
            result = search_quicknotes(self.root, "word")
        self.assertTrue(result["incomplete"])
        self.assertEqual(result["files_scanned"], 1)
        self.assertEqual([hit["path"] for hit in result["hits"]], ["good.md"])
        self.assertEqual([(item["code"], item["path"]) for item in result["diagnostics"]],
                         [("FILE_READ_FAILED", "bad.md")])

    def test_child_directory_inspection_failure_is_partial_but_root_failure_is_fatal(self):
        child = self.write("child/inside.md", b"word").parent
        self.write("good.md", b"word")
        child_checks = 0

        def inspect(path):
            nonlocal child_checks
            if path == child:
                child_checks += 1
                if child_checks > 1:
                    raise OSError("child inspection failed")
            return _inspect(path)

        with patch("mdh_db.quicknotes_search._inspect", side_effect=inspect):
            result = search_quicknotes(self.root, "word")
        self.assertTrue(result["incomplete"])
        self.assertEqual([hit["path"] for hit in result["hits"]], ["good.md"])
        self.assertEqual(result["diagnostics"][0]["code"], "DIRECTORY_READ_FAILED")

        fetch_stat = Path.stat

        def inspect_root(path, **kwargs):
            if path == self.root:
                raise OSError("root inspection failed")
            return fetch_stat(path, **kwargs)

        with patch.object(Path, "stat", inspect_root):
            with self.assertRaisesRegex(OSError, "root inspection failed"):
                search_quicknotes(self.root, "word")

    def test_cloud_file_and_directory_are_read_without_output_validation(self):
        path = self.write("cloud/managed.md", b"word")
        lstat = Path.lstat

        def cloud_stat(candidate):
            info = lstat(candidate)
            if candidate in (path, path.parent):
                values = {name: getattr(info, name) for name in
                          ("st_mode", "st_ino", "st_dev", "st_size", "st_ctime_ns", "st_mtime_ns")}
                return SimpleNamespace(**values, st_file_attributes=stat.FILE_ATTRIBUTE_REPARSE_POINT,
                                       st_reparse_tag=0x9000301A)
            return info

        with patch.object(Path, "lstat", cloud_stat), patch(
                "mdh_db.aggregate_output.OutputDirectory", side_effect=AssertionError("output validation")):
            result = search_quicknotes(self.root, "word")
        self.assertFalse(result["incomplete"])
        self.assertEqual([hit["path"] for hit in result["hits"]], ["cloud/managed.md"])
        self.assertEqual(result["diagnostics"], [])
        self.assertEqual(path.read_bytes(), b"word")

    @unittest.skipUnless(os.name == "nt", "requires Windows junctions")
    def test_junction_root_is_allowed_and_child_escape_and_cycle_are_skipped(self):
        actual = self.root
        self.write("real.md", b"word")
        outside = actual.parent / "outside"
        outside.mkdir()
        (outside / "secret.md").write_bytes(b"word")

        def junction(alias, destination):
            subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(alias), str(destination)],
                           check=True, capture_output=True)
            self.addCleanup(alias.rmdir)

        junction(actual / "escape", outside)
        junction(actual / "cycle", actual)
        alias = actual.parent / "junction root"
        junction(alias, actual)
        result = search_quicknotes(alias, "word")
        self.assertEqual([h["path"] for h in result["hits"]], ["real.md"])
        self.assertEqual(result["files_scanned"], 1)
        self.assertFalse(result["incomplete"])
        self.assertEqual([d["code"] for d in result["diagnostics"]], ["SKIPPED_REPARSE_POINT"] * 2)

        guid_root = actual.parent / "GUID junction root"
        junction(guid_root, volume_alias(actual))
        self.assertIn("Volume{", os.readlink(guid_root))
        self.assertEqual(search_quicknotes(guid_root, "word"), result)

    def test_symbolic_link_is_skipped(self):
        original = self.write("ordinary.md", b"word")
        try:
            (self.root / "alias.md").symlink_to(original)
        except OSError as error:
            if getattr(error, "winerror", None) == 1314:
                self.skipTest("Windows symbolic-link privilege unavailable")
            raise
        result = search_quicknotes(self.root, "word")
        self.assertEqual(result["files_matched"], 1)
        self.assertEqual(result["diagnostics"][0]["code"], "SKIPPED_REPARSE_POINT")

    @unittest.skipUnless(os.name == "nt", "requires Windows reparse attributes")
    def test_unrecognized_reparse_attribute_is_skipped_before_reading(self):
        path = self.write("reparse.md", b"word")
        original = Path.lstat
        marker = SimpleNamespace(st_mode=stat.S_IFREG, st_file_attributes=stat.FILE_ATTRIBUTE_REPARSE_POINT)
        with patch.object(Path, "lstat", lambda p: marker if p == path else original(p)):
            result = search_quicknotes(self.root, "word")
        self.assertFalse(result["incomplete"])
        self.assertEqual(result["files_scanned"], 0)
        self.assertEqual(result["diagnostics"][0]["code"], "SKIPPED_REPARSE_POINT")

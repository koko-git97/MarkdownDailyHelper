from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parents[2] / "40_scripts" / "py_scripts"
sys.path.insert(0, str(SCRIPTS))

from mdh_db.generation import _writer_lock

RAW = (HERE / "fixtures" / "new_daily_crlf.md").read_bytes()
BAD = (HERE / "fixtures" / "sync_invalid.md").read_bytes()


@unittest.skipUnless(sys.platform == "win32", "Windows DB integration")
class CliTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.store = self.base / "派生 DB"
        self.daily = self.base / "人工 日報"
        self.daily.mkdir()

    def write(self, day, raw=RAW):
        name = f"2026/2026-11/2026-11-{day:02}.md"
        path = self.daily / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return path

    def command(self, operation, *args, expected=0, no_dependencies=False):
        env = os.environ.copy()
        flags = []
        if no_dependencies:
            env.pop("PYTHONPATH", None)
            flags.append("-S")
        command = [sys.executable, "-B", *flags, "-m", "mdh_db", operation]
        if operation != "environment":
            command += [f"--store={self.store}"]
        if operation in ("sync", "rebuild"):
            command += [f"--daily-root={self.daily}"]
        process = subprocess.run(command + list(args), cwd=SCRIPTS, env=env, capture_output=True, timeout=15)
        payload = json.loads(process.stdout.decode("utf-8"))
        self.assertEqual(set(payload), {"contract_version", "operation", "exit_code", "result", "diagnostics"})
        self.assertEqual((process.returncode, payload["exit_code"], payload["contract_version"], payload["operation"]),
                         (expected, expected, 1, operation), payload)
        return payload

    def test_readonly_uninitialized_status_and_failed_search_sync_do_not_create_store(self):
        status = self.command("status")["result"]
        self.assertFalse(status["initialized"])
        self.assertTrue(status["incomplete"])
        self.command("search", "--query=日報", expected=4)
        self.assertFalse(self.store.exists())
        # I5 also keeps a sync request against an uninitialized store side-effect free.
        self.command("sync", expected=4)
        self.assertFalse(self.store.exists())

    def test_status_reports_indexed_root_and_search_rejects_a_different_root(self):
        self.write(22)
        self.command("rebuild")
        other = self.base / "new Daily root"
        other.mkdir()
        matching = self.command("status", f"--daily-root={self.daily}")["result"]
        self.assertTrue(matching["daily_root_matches"])
        self.assertEqual(Path(matching["daily_root"]), self.daily.resolve())
        self.assertTrue(self.command("search", f"--daily-root={self.daily}", "--query=貸出集計")["result"]["hits"])

        status = self.command("status", f"--daily-root={other}", expected=4)
        self.assertEqual(status["diagnostics"][0]["code"], "DAILY_ROOT_MISMATCH")
        self.assertFalse(status["result"]["daily_root_matches"])
        self.assertEqual(Path(status["result"]["daily_root"]), self.daily.resolve())
        self.assertEqual(Path(status["result"]["configured_daily_root"]), other)
        search = self.command("search", f"--daily-root={other}", "--query=貸出集計", expected=4)
        self.assertEqual(search["diagnostics"][0]["code"], "DAILY_ROOT_MISMATCH")
        self.assertIsNone(search["result"])

    def test_unicode_rebuild_search_and_status_keep_json_and_original_bytes(self):
        path = self.write(22)
        published = self.command("rebuild")["result"]
        self.assertEqual(published["indexed"], 1)
        db = Path(published["path"])
        before = db.read_bytes()
        result = self.command("search", "--query=図書A　貸出集計", "--from=2026-11-22", "--to=2026-11-22")["result"]
        hit, = result["hits"]
        self.assertEqual(hit["title"], "図書A")
        self.assertEqual(hit["matches"][1]["excerpt"], "貸出集計")
        self.assertFalse(hit["from_last_good_snapshot"])
        self.assertEqual(self.command("status")["result"]["counts"]["CURRENT"], 1)
        self.assertEqual(self.command("search", "--query=該当なし")["result"]["hits"], [])
        self.assertEqual(db.read_bytes(), before)
        self.assertEqual(path.read_bytes(), RAW)

    def test_first_rebuild_rechecks_store_before_publishing(self):
        self.write(22)
        published = self.command("rebuild", "--only-if-uninitialized")["result"]["path"]
        pointer = self.store / "active"
        previous = pointer.read_bytes()
        failure = self.command("rebuild", "--only-if-uninitialized", expected=6)
        self.assertEqual(failure["diagnostics"][0]["code"], "ALREADY_INITIALIZED")
        self.assertEqual(pointer.read_bytes(), previous)

        pointer.write_bytes(b"broken")
        failure = self.command("rebuild", "--only-if-uninitialized", expected=4)
        self.assertEqual(failure["diagnostics"][0]["code"], "ACTIVE_DATABASE_ERROR")
        self.assertEqual(pointer.read_bytes(), b"broken")
        self.assertEqual(list(self.store.glob("db-*.sqlite")), [Path(published)])

    def test_partial_sync_and_stale_search_keep_details_even_for_zero_hits(self):
        original = self.write(22)
        self.command("rebuild")
        initial = self.command("status")["result"]["last_full_success"]
        original.write_bytes(BAD)
        self.write(23, RAW.replace("貸出集計".encode(), "追加の結果".encode()))
        partial = self.command("sync", expected=1)
        self.assertEqual((partial["result"]["indexed"], partial["result"]["failed"]), (1, 1))
        self.assertTrue(partial["diagnostics"])
        zero = self.command("search", "--query=貸出集計")["result"]
        self.assertEqual((zero["hits"], zero["excluded"]["STALE"], zero["last_full_success"]), ([], 1, initial))
        self.assertTrue(zero["incomplete"])
        stale = self.command("search", "--query=貸出集計", "--include-stale",
                             "--from=2026-11-22", "--to=2026-11-22")["result"]["hits"][0]
        self.assertTrue(stale["from_last_good_snapshot"])
        self.assertEqual(stale["status"], "STALE")

    def test_deletion_argument_only_accepts_observed_relative_daily_and_individual_confirmation(self):
        target = self.write(20)
        self.write(21, RAW + b"\n<!-- 21 -->")
        self.write(22, RAW + b"\n<!-- 22 -->")
        self.command("rebuild")
        for path in ("../2026-11-20.md", r"2026\..\2026-11-20.md", str(target),
                     "README.md", "2026/2026-11/2026-11-25.md"):
            with self.subTest(path=path):
                self.command("sync", f"--confirm-deletion={path}", expected=2)
        target.unlink()
        argument = r"--confirm-deletion=2026\2026-11\2026-11-20.md"
        self.assertEqual(self.command("sync", argument, expected=1)["result"]["deleted"], 0)
        self.assertEqual(self.command("sync", argument)["result"]["deleted"], 1)

    def test_invalid_date_and_dependency_errors_have_versioned_json(self):
        self.command("search", "--query=x", "--from=2026-02-30", expected=2)
        self.command("search", "--query=x", "--from=2026-11-23", "--to=2026-11-22", expected=2)
        result = self.command("environment", no_dependencies=True, expected=3)
        self.assertIn("markdown-it-py", result["diagnostics"][0]["message"])
        environment = self.command("environment")["result"]
        self.assertEqual(environment["dependencies"]["markdown-it-py"], "3.0.0")

    def test_lock_and_rebuild_failure_leave_previous_generation_searchable(self):
        self.write(22)
        self.command("rebuild")
        pointer = self.store / "active"
        before = pointer.read_bytes()
        with _writer_lock(self.store):
            self.command("sync", expected=5)
            self.command("rebuild", expected=5)
        self.write(23, BAD)
        self.command("rebuild", expected=6)
        self.assertEqual(pointer.read_bytes(), before)
        self.assertTrue(self.command("search", "--query=貸出集計")["result"]["hits"])

    def test_pointer_corruption_reference_missing_and_schema_mismatch_all_report_db_error(self):
        self.write(22)
        published = Path(self.command("rebuild")["result"]["path"])
        pointer = self.store / "active"
        original = pointer.read_bytes()
        pointer.write_bytes(b"broken")
        self.command("status", expected=4)
        self.command("rebuild", expected=4)
        pointer.write_bytes(b"db-00000000000000000000000000000000.sqlite\n")
        self.command("search", "--query=x", expected=4)
        pointer.write_bytes(original)
        with closing(sqlite3.connect(published)) as db:
            db.execute("PRAGMA user_version=2")
        self.command("status", expected=4)
        self.command("rebuild", expected=4)

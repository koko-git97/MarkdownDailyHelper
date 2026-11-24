from contextlib import closing
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
from tempfile import TemporaryDirectory
from time import monotonic, sleep
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "40_scripts" / "py_scripts"))
FIXTURES = HERE / "fixtures"

if sys.platform == "win32":
    import mdh_db.generation as gen
    import mdh_db.sync as sync
    from mdh_db.storage import DatabaseIntegrityError, open_database, transaction

RAW = (FIXTURES / "new_daily_crlf.md").read_bytes()
BAD = (FIXTURES / "sync_invalid.md").read_bytes()
NEW = RAW.replace("貸出集計".encode(), "再構築後".encode())


def writer_child(store: Path, root: Path, ready: Path, operation: str):
    parser = sync.parse_daily
    calls = 0

    def interrupted(raw):
        nonlocal calls
        calls += 1
        if operation == "crash" and calls == 2:
            os._exit(23)
        if operation == "sync":
            ready.touch()
            sleep(30)
        return parser(raw)

    if operation == "after-publication":
        replace = os.replace

        def publish_then_abort(source, target):
            replace(source, target)
            os._exit(24)

        with patch.object(gen.os, "replace", side_effect=publish_then_abort):
            gen.rebuild(store, root)
        return


    with patch.object(sync, "parse_daily", side_effect=interrupted):
        if operation == "sync":
            gen.sync_active(store, root)
        else:
            gen.rebuild(store, root)


@unittest.skipUnless(sys.platform == "win32", "Windows generation store")
class GenerationTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.root = self.base / "原文"
        self.root.mkdir()
        self.store = self.base / "派生 DB"

    def write(self, day, raw=None, month=11):
        folder = self.root / f"2026/2026-{month:02}"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"2026-{month:02}-{day:02}.md"
        path.write_bytes(raw if raw is not None else RAW + f"\r\n<!-- {month}-{day} -->\r\n".encode())
        return path

    def relative(self, path):
        return path.relative_to(self.root).as_posix()

    def rebuild(self):
        return gen.rebuild(self.store, self.root)

    def state(self, db_path, source):
        with open_database(db_path) as db:
            return db.execute("SELECT status, snapshot_id, missing_streak FROM sync_file WHERE source_path=?",
                              (self.relative(source),)).fetchone()

    def assert_block(self, code, previous, missing=()):
        pointer = (self.store / "active").read_bytes()
        with self.assertRaises(gen.PublicationBlocked) as error:
            self.rebuild()
        self.assertEqual(error.exception.code, code)
        self.assertEqual(error.exception.paths, tuple(sorted(self.relative(path) for path in missing)))
        self.assertEqual((self.store / "active").read_bytes(), pointer)
        self.assertEqual(gen.active_path(self.store), previous)

    def test_first_build_and_new_daily_preserve_original_bytes(self):
        first = self.write(21)
        before = first.read_bytes()
        published = self.rebuild()
        self.assertEqual(published.indexed, 1)
        self.assertEqual((self.store / "active").read_bytes(), published.path.name.encode() + b"\n")
        added = self.write(22, NEW)
        next_build = self.rebuild()
        self.assertEqual(next_build.indexed, 2)
        self.assertNotEqual(published.path, next_build.path)
        self.assertTrue(published.path.is_file())
        self.assertEqual(len(gen.search_active(self.store, "再構築後").hits), 1)
        self.assertEqual((first.read_bytes(), added.read_bytes()), (before, NEW))

    def test_unconfirmed_and_missing_states_block_without_old_state_changes(self):
        first = self.write(21)
        self.write(22)
        self.write(23)
        previous = self.rebuild().path
        first.unlink()
        self.assert_block("UNCONFIRMED_ABSENCE", previous, [first])
        self.assertEqual(self.state(previous, first)[0], "CURRENT")
        gen.sync_active(self.store, self.root)
        missing = self.state(previous, first)
        self.assertEqual(missing[0], "MISSING")
        self.assert_block("UNCONFIRMED_ABSENCE", previous, [first])
        self.assertEqual(self.state(previous, first), missing)

    def test_deleted_a_allows_rebuild_but_does_not_approve_missing_b(self):
        a, b, _ = (self.write(day) for day in (21, 22, 23))
        previous = self.rebuild().path
        a.unlink()
        self.assertEqual(gen.sync_active(self.store, self.root).deleted, 0)
        self.assertEqual(gen.sync_active(self.store, self.root, confirm_deletions=[self.relative(a)]).deleted, 1)
        deleted = self.state(previous, a)
        self.assertEqual(deleted[0], "DELETED")
        original_b = b.read_bytes()
        b.unlink()
        self.assert_block("UNCONFIRMED_ABSENCE", previous, [b])
        self.assertEqual(self.state(previous, a), deleted)
        b.write_bytes(original_b)
        published = self.rebuild()
        self.assertEqual(published.indexed, 2)
        self.assertIsNone(self.state(published.path, a))
        self.assertEqual(self.state(previous, a), deleted)

    def test_old_stale_and_invalid_can_recover_but_remaining_error_blocks(self):
        stale = self.write(21)
        previous = self.rebuild().path
        stale.write_bytes(BAD)
        invalid = self.write(22, BAD)
        gen.sync_active(self.store, self.root)
        self.assertEqual((self.state(previous, stale)[0], self.state(previous, invalid)[0]), ("STALE", "INVALID"))
        self.assert_block("FULL_BUILD_FAILED", previous, [stale, invalid])
        stale.write_bytes(RAW)
        invalid.write_bytes(NEW)
        current = self.rebuild().path
        self.assertEqual((self.state(current, stale)[0], self.state(current, invalid)[0]), ("CURRENT", "CURRENT"))
        self.assertEqual((self.state(previous, stale)[0], self.state(previous, invalid)[0]), ("STALE", "INVALID"))

    def test_missing_worklog_does_not_publish_or_change_active_db(self):
        source = self.write(21)
        previous = self.rebuild().path
        old_bytes = previous.read_bytes()
        old_state = self.state(previous, source)
        old_generations = set(self.store.glob("db-*.sqlite"))
        missing = (FIXTURES / "worklog_missing.md").read_bytes()
        source.write_bytes(missing)
        diagnostics = []

        def record_candidate_sync(*args, **kwargs):
            result = sync.synchronize(*args, **kwargs)
            diagnostics.extend(result.diagnostics)
            return result

        with patch.object(gen, "_sync_database", side_effect=record_candidate_sync):
            self.assert_block("FULL_BUILD_FAILED", previous, [source])
        self.assertEqual([(d.path, d.code) for d in diagnostics],
                         [(self.relative(source), "WORKLOG_MISSING")])
        self.assertEqual(set(self.store.glob("db-*.sqlite")), old_generations)
        self.assertEqual(previous.read_bytes(), old_bytes)
        self.assertEqual(self.state(previous, source), old_state)
        self.assertEqual(len(gen.search_active(self.store, "貸出集計").hits), 1)
        self.assertEqual(source.read_bytes(), missing)

    def test_partially_missing_directory_and_empty_input_hold_old_generation(self):
        gone = [self.write(day, month=10) for day in (20, 21)]
        others = [self.write(day) for day in (22, 23)]
        previous = self.rebuild().path
        for path in gone:
            path.unlink()
        gone[0].parent.rmdir()
        self.assert_block("MASS_ABSENCE", previous, gone)
        for path in others:
            path.unlink()
        self.assert_block("MASS_ABSENCE", previous, [*gone, *others])

    def test_wrong_root_scan_failure_and_input_change_never_publish(self):
        self.write(21)
        previous = self.rebuild().path
        other = self.base / "other"
        other.mkdir()
        with self.assertRaisesRegex(gen.PublicationBlocked, "ACTIVE_ROOT_MISMATCH"):
            gen.rebuild(self.store, other)
        with patch.object(gen, "_scan", side_effect=PermissionError("scan denied")):
            with self.assertRaisesRegex(PermissionError, "scan denied"):
                self.rebuild()
        file = self.write(21, NEW)
        parse = sync.parse_daily

        def drift(raw):
            file.write_bytes(RAW)
            return parse(raw)

        with patch.object(sync, "parse_daily", side_effect=drift):
            self.assert_block("SOURCE_CHANGED_DURING_BUILD", previous)
        self.assertTrue(gen.search_active(self.store, "貸出集計").hits)

    def test_existing_windows_reader_pins_old_wal_while_new_reader_sees_new_generation(self):
        self.write(21)
        previous = self.rebuild().path
        with open_database(previous, read_only=False) as writer:
            self.assertEqual(writer.execute("PRAGMA journal_mode=WAL").fetchone(), ("wal",))
            with transaction(writer, write=True):
                writer.execute("UPDATE metadata SET last_attempt='wal write'")
            wal = previous.with_name(previous.name + "-wal")
            shm = previous.with_name(previous.name + "-shm")
            self.assertTrue(wal.exists() and shm.exists())
            with open_database(gen.active_path(self.store)) as reader, transaction(reader):
                self.assertTrue(reader.execute("SELECT 1 FROM search_document WHERE instr(body, '貸出集計')").fetchone())
                self.write(21, NEW)
                current = self.rebuild().path
                self.assertNotEqual(previous, current)
                self.assertFalse(reader.execute("SELECT 1 FROM search_document WHERE instr(body, '再構築後')").fetchone())
                self.assertTrue(wal.exists() and shm.exists())
                self.assertTrue(gen.search_active(self.store, "再構築後").hits)
                self.assertFalse(current.with_name(current.name + "-wal").exists())

    def test_real_windows_pointer_lock_gets_two_retries_and_keeps_old_searchable(self):
        self.write(21)
        previous = self.rebuild().path
        self.write(21, NEW)
        pointer = self.store / "active"
        with pointer.open("rb"), patch.object(gen, "sleep") as sleeping:
            with self.assertRaises(OSError):
                self.rebuild()
            self.assertEqual([call.args[0] for call in sleeping.call_args_list], [0.1, 0.3])
        self.assertEqual(gen.active_path(self.store), previous)
        self.assertTrue(gen.search_active(self.store, "貸出集計").hits)
        self.assertGreater(len(list(self.store.glob("db-*.sqlite"))), 1)
        self.rebuild()
        self.assertTrue(gen.search_active(self.store, "再構築後").hits)

    def test_access_denied_without_sharing_evidence_is_not_retried(self):
        self.write(21)
        previous = self.rebuild().path
        self.write(21, NEW)
        with patch.object(gen.os, "replace", side_effect=gen.ctypes.WinError(5)) as replace, \
                patch.object(gen, "sleep") as sleeping:
            with self.assertRaises(OSError):
                self.rebuild()
            self.assertEqual(replace.call_count, 1)
            sleeping.assert_not_called()
        self.assertEqual(gen.active_path(self.store), previous)
        self.assertTrue(gen.search_active(self.store, "貸出集計").hits)

    def test_integrity_failure_cannot_publish_candidate(self):
        self.write(21)
        previous = self.rebuild().path
        self.write(21, NEW)

        def broken(candidate, root):
            result = sync.synchronize(candidate, root)
            with closing(sqlite3.connect(candidate)) as db:
                db.execute("PRAGMA foreign_keys=OFF")
                db.execute("UPDATE search_document SET daily_id=999")
                db.commit()
            return result

        with patch.object(gen, "_sync_database", side_effect=broken):
            with self.assertRaisesRegex(DatabaseIntegrityError, "foreign_key_check"):
                self.rebuild()
        self.assertEqual(gen.active_path(self.store), previous)
        self.assertTrue(gen.search_active(self.store, "貸出集計").hits)

    def test_corrupt_or_missing_pointer_does_not_select_another_generation(self):
        self.write(21)
        original = self.rebuild().path
        pointer = self.store / "active"
        for content in (b"../escape.sqlite\n", b"..\\escape.sqlite\n", b"C:\\escape.sqlite\n",
                        original.name.encode() + b"\nextra", original.name.encode(), original.name.encode() + b"\r\n",
                        b"db-00000000000000000000000000000000.sqlite\n"):
            with self.subTest(content=content):
                pointer.write_bytes(content)
                with self.assertRaises(gen.GenerationError):
                    gen.search_active(self.store, "")
                with self.assertRaises(gen.GenerationError):
                    gen.sync_active(self.store, self.root)
                with self.assertRaises(gen.GenerationError):
                    self.rebuild()
                self.assertEqual(pointer.read_bytes(), content)
        pointer.unlink()
        with self.assertRaises(gen.GenerationError):
            self.rebuild()
        self.assertTrue(original.is_file())

    def start_child(self, operation, ready):
        env = dict(os.environ, PYTHONPATH=os.pathsep.join(path for path in sys.path if path))
        return subprocess.Popen([sys.executable, "-B", __file__, str(self.store), str(self.root),
                                 str(ready), operation], env=env, stderr=subprocess.PIPE)

    def test_sync_lock_blocks_other_writers_and_process_exit_releases_lock(self):
        self.write(21)
        previous = self.rebuild().path
        self.write(21, NEW)
        ready = self.base / "sync-ready"
        with self.start_child("sync", ready) as child:
            try:
                limit = monotonic() + 12
                while not ready.exists() and child.poll() is None and monotonic() < limit:
                    sleep(0.03)
                self.assertTrue(ready.exists(), "child did not enter sync while holding the lock")
                with self.assertRaises(gen.WriterBusy):
                    self.rebuild()
                with self.assertRaises(gen.WriterBusy):
                    gen.sync_active(self.store, self.root)
                self.assertEqual(gen.active_path(self.store), previous)
                self.assertTrue(gen.search_active(self.store, "貸出集計").hits)
            finally:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=15)
        self.assertEqual(gen.sync_active(self.store, self.root).indexed, 1)

    def test_crash_before_publication_does_not_expose_candidate(self):
        self.write(21)
        previous = self.rebuild().path
        self.write(21, NEW)
        self.write(22, NEW)
        with self.start_child("crash", self.base / "unused") as child:
            try:
                _, stderr = child.communicate(timeout=15)
                self.assertEqual(child.returncode, 23, stderr)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.communicate()
        self.assertEqual(gen.active_path(self.store), previous)
        self.assertFalse(gen.search_active(self.store, "再構築後").hits)
        self.assertTrue(list(self.store.glob("build-*.sqlite")))
        self.assertEqual(self.rebuild().indexed, 2)

    def test_identical_replacement_at_another_path_is_not_confirmation(self):
        day = self.write(21)
        self.write(22)
        self.write(23)
        previous = self.rebuild().path
        same_bytes = day.read_bytes()
        day.unlink()
        self.write(24, same_bytes)
        self.assert_block("UNCONFIRMED_ABSENCE", previous, [day])

    def test_restored_missing_daily_is_rebuilt_without_changing_old_state(self):
        day = self.write(21)
        self.write(22)
        previous = self.rebuild().path
        day.unlink()
        gen.sync_active(self.store, self.root)
        self.assertEqual(self.state(previous, day)[0], "MISSING")
        day.write_bytes(NEW)
        current = self.rebuild().path
        self.assertEqual(self.state(previous, day)[0], "MISSING")
        self.assertEqual(self.state(current, day)[0], "CURRENT")

    def test_exit_after_pointer_commit_leaves_completed_generation_active(self):
        self.write(21)
        previous = self.rebuild().path
        self.write(21, NEW)
        with self.start_child("after-publication", self.base / "unused") as child:
            try:
                _, stderr = child.communicate(timeout=15)
                self.assertEqual(child.returncode, 24, stderr)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.communicate()
        self.assertNotEqual(gen.active_path(self.store), previous)
        self.assertTrue(previous.is_file())
        self.assertTrue(gen.search_active(self.store, "再構築後").hits)
        self.assertEqual(gen.sync_active(self.store, self.root).unchanged, 1)


    def test_rebuild_lock_blocks_sync_before_the_candidate_is_published(self):
        self.write(21)
        previous = self.rebuild().path
        self.write(21, NEW)
        publish = gen._publish

        def check_lock(store, candidate):
            with self.assertRaises(gen.WriterBusy):
                gen.sync_active(store, self.root)
            self.assertEqual(gen.active_path(store), previous)
            publish(store, candidate)

        with patch.object(gen, "_publish", side_effect=check_lock):
            self.rebuild()
        self.assertTrue(gen.search_active(self.store, "再構築後").hits)


if __name__ == "__main__":
    writer_child(*(Path(value) for value in sys.argv[1:4]), sys.argv[4])

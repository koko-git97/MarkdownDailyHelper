from datetime import date
from hashlib import sha256
from pathlib import Path
import sqlite3
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
sys.path.insert(0, str(HERE.parents[2] / "40_scripts" / "py_scripts"))

from mdh_db.parser import ParseError
from mdh_db.search import search
from mdh_db.storage import check_integrity, create_database, open_database, transaction
import mdh_db.sync as sync

RAW = (FIXTURES / "new_daily_crlf.md").read_bytes()
BAD = (FIXTURES / "sync_invalid.md").read_bytes()


class SyncTests(unittest.TestCase):
    def setUp(self):
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "日報"
        self.root.mkdir()
        self.db = Path(tmp.name) / "test.sqlite"
        create_database(self.db, root_identity=sync.daily_root_identity(self.root))

    def write(self, day, raw=None):
        path = self.root / f"2026/2026-11/2026-11-{day:02}.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw if raw is not None else RAW + f"\r\n<!-- fixture {day} -->\r\n".encode())
        return path

    def run_sync(self, **options):
        return sync.synchronize(self.db, self.root, **options)

    def relative(self, path):
        return path.relative_to(self.root).as_posix()

    def state(self, path):
        with open_database(self.db) as db:
            return db.execute("""
                SELECT status, day, observed_hash, diagnosis, missing_streak, snapshot_id
                FROM sync_file WHERE source_path=?
            """, (self.relative(path),)).fetchone()

    def snapshots(self):
        with open_database(self.db) as db:
            check_integrity(db)
            return {table: db.execute(f"SELECT * FROM {table} ORDER BY 1,2").fetchall()
                    for table in ("daily", "topic", "section", "completion", "search_document")}

    def test_initial_sync_skip_update_and_original_bytes(self):
        path = self.write(22)
        original = path.read_bytes()
        with patch.object(sync, "parse_daily", wraps=sync.parse_daily) as parser:
            first = self.run_sync()
            self.assertEqual((first.indexed, first.completed), (1, True))
            self.assertEqual(first.last_attempt, first.last_full_success)
            daily_id = self.state(path)[5]
            same = self.run_sync()
            self.assertEqual((same.indexed, same.unchanged, parser.call_count), (0, 1, 1))
            changed = original.replace("貸出集計".encode(), "新内容".encode())
            path.write_bytes(changed)
            self.assertEqual(self.run_sync().indexed, 1)
            self.assertEqual(self.state(path)[5], daily_id)
            self.assertEqual(self.state(path)[2], sha256(changed).hexdigest())
            self.assertEqual(sha256(path.read_bytes()).digest(), sha256(changed).digest())
            self.assertEqual(len(search(self.db, "新内容").hits), 1)
            self.assertFalse(search(self.db, "貸出集計").hits)
        data = self.snapshots()
        self.assertEqual(len(data["topic"]), 2)
        self.assertEqual([row[4] for row in data["section"]], [3, 4, 3])
        self.assertEqual(data["completion"][0][-2:], ("図書", "整理📚"))

    def test_partial_success_and_stale_retains_normal_snapshot(self):
        path = self.write(21)
        good_run = self.run_sync()
        previous = self.snapshots()
        path.write_bytes(BAD)
        self.write(22, RAW.replace("貸出集計".encode(), "追加結果".encode()))
        invalid = self.write(23, BAD)
        run = self.run_sync()
        self.assertEqual((run.indexed, run.failed, run.completed), (1, 2, False))
        self.assertEqual(run.last_full_success, good_run.last_full_success)
        self.assertEqual(self.state(path)[0], "STALE")
        self.assertEqual(self.state(invalid)[0], "INVALID")
        self.assertIsNone(self.state(invalid)[5])
        for table, rows in previous.items():
            self.assertEqual(rows, [row for row in self.snapshots()[table] if row[0] == 1])
        self.assertFalse(search(self.db, "貸出集計").hits)
        stale, = search(self.db, "貸出集計", include_stale=True).hits
        self.assertTrue(stale.from_last_good_snapshot)
        self.assertTrue(search(self.db, "追加結果").incomplete)
        self.assertEqual(path.read_bytes(), BAD)

    def test_missing_worklog_keeps_last_good_snapshot(self):
        path = self.write(22)
        previous = self.run_sync()
        snapshots = self.snapshots()
        previous_id = self.state(path)[5]
        missing = (FIXTURES / "worklog_missing.md").read_bytes()
        path.write_bytes(missing)

        result = self.run_sync()

        self.assertEqual((result.indexed, result.failed, result.completed), (0, 1, False))
        self.assertEqual(result.last_full_success, previous.last_full_success)
        self.assertEqual([(d.path, d.code) for d in result.diagnostics],
                         [(self.relative(path), "WORKLOG_MISSING")])
        state = self.state(path)
        self.assertEqual((state[0], state[5]), ("STALE", previous_id))
        self.assertEqual(self.snapshots(), snapshots)
        self.assertFalse(search(self.db, "貸出集計").hits)
        hit, = search(self.db, "貸出集計", include_stale=True).hits
        self.assertTrue(hit.from_last_good_snapshot)
        self.assertEqual(path.read_bytes(), missing)

    def test_concurrent_source_changes_preserve_snapshot_and_retry(self):
        path = self.write(22)
        original = path.read_bytes()
        staged = original.replace("貸出集計".encode(), "中間内容".encode())
        latest = original.replace("貸出集計".encode(), "最新内容".encode())
        self.run_sync()
        real_parser, replace = sync.parse_daily, sync._replace_snapshot

        for phase in ("hash", "parse", "transaction", "before_commit", "deleted"):
            with self.subTest(phase=phase):
                path.write_bytes(original)
                self.run_sync()
                before = self.snapshots()
                # Also exercise the unchanged shortcut in the hash case.
                if phase != "hash":
                    path.write_bytes(staged)

                def hash_then_edit(raw):
                    digest = sha256(raw)
                    path.write_bytes(latest)
                    return digest

                def parse_then_edit(raw):
                    path.write_bytes(latest)
                    return real_parser(raw)

                def replace_then_edit(*args):
                    self.assertTrue(args[0].in_transaction)
                    if phase == "transaction":
                        path.write_bytes(latest)
                        replace(*args)
                        return
                    replace(*args)
                    if phase == "deleted":
                        path.unlink()
                    else:
                        path.write_bytes(latest)

                hooks = {
                    "hash": patch.object(sync, "sha256", side_effect=hash_then_edit),
                    "parse": patch.object(sync, "parse_daily", side_effect=parse_then_edit),
                    "transaction": patch.object(sync, "_replace_snapshot", side_effect=replace_then_edit),
                    "before_commit": patch.object(sync, "_replace_snapshot", side_effect=replace_then_edit),
                    "deleted": patch.object(sync, "_replace_snapshot", side_effect=replace_then_edit),
                }
                with hooks[phase]:
                    result = self.run_sync()
                self.assertEqual((result.failed, result.completed), (1, False))
                self.assertEqual(result.diagnostics[0].code, "DAILY_SOURCE_CHANGED")
                self.assertEqual(self.state(path)[0], "STALE")
                self.assertEqual(self.snapshots(), before)
                if phase == "deleted":
                    self.assertFalse(path.exists())
                    path.write_bytes(latest)
                self.assertEqual(path.read_bytes(), latest)
                self.assertEqual(self.run_sync().indexed, 1)
                self.assertEqual(self.run_sync().unchanged, 1)
                self.assertEqual(self.state(path)[0], "CURRENT")

    def test_first_sync_source_change_leaves_no_snapshot(self):
        path = self.write(22)
        latest = RAW.replace("貸出集計".encode(), "最新内容".encode())
        real_parser = sync.parse_daily

        def edit_during_parse(raw):
            path.write_bytes(latest)
            return real_parser(raw)

        with patch.object(sync, "parse_daily", side_effect=edit_during_parse):
            result = self.run_sync()
        self.assertEqual((result.failed, result.completed), (1, False))
        self.assertEqual(self.state(path)[0], "INVALID")
        self.assertTrue(all(not rows for rows in self.snapshots().values()))
        self.assertEqual(path.read_bytes(), latest)
        self.assertEqual(self.run_sync().indexed, 1)

    def test_same_failed_hash_retried_even_when_equal_to_last_good(self):
        path = self.write(22)
        raw = path.read_bytes()
        self.run_sync()
        path.write_bytes(BAD)
        self.run_sync()
        path.write_bytes(raw)
        real_parser = sync.parse_daily
        with patch.object(sync, "parse_daily", side_effect=[ParseError("INJECTED"), real_parser(raw)]) as parse:
            self.assertEqual(self.run_sync().failed, 1)
            self.assertEqual(self.state(path)[2], sha256(raw).hexdigest())
            self.assertEqual(self.run_sync().indexed, 1)
            self.assertEqual(parse.call_count, 2)
        self.assertEqual(self.state(path)[0], "CURRENT")

    def test_sql_failure_rolls_back_every_prior_change_then_records_stale(self):
        path = self.write(22)
        self.run_sync()
        before = self.snapshots()
        raw = RAW.replace("貸出集計".encode(), "注入失敗".encode())
        path.write_bytes(raw)
        with open_database(self.db, read_only=False) as db, transaction(db, write=True):
            db.execute("""
                CREATE TRIGGER reject_span BEFORE INSERT ON search_document
                WHEN instr(NEW.body, '注入失敗') > 0 BEGIN
                    SELECT RAISE(ABORT, 'injected SQL failure');
                END
            """)
        result = self.run_sync()
        self.assertEqual((result.failed, result.completed), (1, False))
        self.assertEqual(result.diagnostics[0].code, "DAILY_DATABASE_WRITE_FAILED")
        self.assertEqual(self.snapshots(), before)
        self.assertEqual(self.state(path)[0], "STALE")
        self.assertEqual(path.read_bytes(), raw)

    def test_scan_classifies_date_and_placement_but_ignores_other_markdown(self):
        nested = self.root / "2026/2026-11"
        nested.mkdir(parents=True)
        ignored = nested / "README.md"
        invalid_date = nested / "2026-02-30.md"
        invalid_folder = nested / "2026-12-01.md"
        for file in (ignored, invalid_date, invalid_folder):
            file.write_bytes(RAW)
        result = self.run_sync()
        self.assertEqual([item.code for item in result.diagnostics],
                         ["INVALID_DAILY_DATE", "INVALID_DAILY_PLACEMENT"])
        self.assertIsNone(self.state(ignored))
        self.assertEqual(self.state(invalid_date)[:2], ("INVALID", None))
        self.assertEqual(self.state(invalid_folder)[:2], ("INVALID", "2026-12-01"))
        coverage = search(self.db, "", after=date(2026, 12, 1))
        self.assertEqual((coverage.undated_invalid, coverage.excluded["INVALID"]), (1, 1))

    def test_moved_and_renamed_daily_holds_original_snapshot(self):
        path = self.write(21)
        self.write(22)
        self.write(23)
        self.run_sync()
        prior = self.state(path)[5]
        moved = self.root / "2026/2026-12/2026-11-21.md"
        moved.parent.mkdir()
        path.rename(moved)
        for _ in range(2):
            result = self.run_sync(confirm_deletions=[self.relative(path)])
            self.assertEqual(result.deleted, 0)
        self.assertEqual(self.state(path)[0], "STALE")
        self.assertEqual(self.state(path)[5], prior)
        self.assertEqual(self.state(moved)[0], "INVALID")
        renamed = moved.with_name("2026-12-21.md")
        moved.rename(renamed)
        for _ in range(2):
            result = self.run_sync(confirm_deletions=[self.relative(path)])
            self.assertEqual(result.deleted, 0)
        self.assertEqual(self.state(path)[0], "MISSING")
        self.assertEqual(self.state(path)[5], prior)
        self.assertIn("POSSIBLE_DAILY_RENAME", [item.code for item in result.diagnostics])

    def test_only_individually_confirmed_paths_are_removed_after_two_scans(self):
        paths = [self.write(day) for day in range(20, 25)]
        first = self.run_sync()
        for path in paths[:2]:
            path.unlink()
        confirmed = [self.relative(paths[0])]
        one = self.run_sync(confirm_deletions=confirmed)
        self.assertEqual((one.missing, one.deleted), (2, 0))
        two = self.run_sync(confirm_deletions=confirmed)
        self.assertEqual((two.missing, two.deleted), (1, 1))
        self.assertEqual(two.last_full_success, first.last_full_success)
        self.assertEqual(self.state(paths[0])[0], "DELETED")
        self.assertEqual(self.state(paths[1])[0], "MISSING")
        self.assertIsNotNone(self.state(paths[1])[5])
        coverage = search(self.db, "", include_stale=True)
        self.assertEqual((coverage.excluded["MISSING"], coverage.excluded["DELETED"]), (1, 1))
        with self.assertRaises(ValueError):
            self.run_sync(confirm_deletions="../anything.md")

    def test_mass_absence_holds_at_half_and_at_total_absence(self):
        paths = [self.write(day) for day in range(20, 24)]
        self.run_sync()
        for target in (paths[:2], paths[2:]):
            for path in target:
                path.unlink()
            for _ in range(2):
                result = self.run_sync(confirm_deletions=[self.relative(path) for path in paths])
                self.assertEqual((result.deletion_guard, result.deleted), ("MASS_ABSENCE", 0))
        self.assertTrue(all(self.state(path)[::4] == ("MISSING", 0) for path in paths))
        self.assertEqual(len(self.snapshots()["daily"]), 4)

    def test_absolute_mass_threshold_over_ten_even_below_half(self):
        paths = [self.write(day) for day in range(1, 24)]
        self.run_sync()
        for path in paths[:11]:
            path.unlink()
        result = self.run_sync(confirm_deletions=[self.relative(path) for path in paths[:11]])
        self.assertEqual((result.missing, result.deleted, result.deletion_guard), (11, 0, "MASS_ABSENCE"))

    def test_scan_and_root_failures_never_infer_deletion_and_reset_streak(self):
        path = self.write(20)
        self.write(21)
        self.run_sync()
        path.unlink()
        self.run_sync()
        with patch.object(sync, "_scan", side_effect=PermissionError("directory denied")):
            failed = self.run_sync(confirm_deletions=[self.relative(path)])
        self.assertFalse(failed.completed)
        self.assertEqual((failed.deleted, self.state(path)[4]), (0, 0))
        wrong = self.root.parent / "wrong"
        wrong.mkdir()
        failed = sync.synchronize(self.db, wrong, confirm_deletions=[self.relative(path)])
        self.assertIsNotNone(failed.scan_error)
        self.assertEqual(self.run_sync(confirm_deletions=[self.relative(path)]).deleted, 0)
        self.assertEqual(self.state(path)[0], "MISSING")

    def test_late_reappearance_rolls_back_other_deletions_in_pass(self):
        paths = [self.write(day) for day in range(20, 25)]
        self.run_sync()
        for path in paths[:2]:
            path.unlink()
        self.run_sync()
        real = sync._still_absent
        second = self.relative(paths[1])
        checks = 0

        def reappear(root, relative):
            nonlocal checks
            if relative == second:
                checks += 1
                if checks == 2:
                    paths[1].write_bytes(RAW)
            return real(root, relative)

        with patch.object(sync, "_still_absent", side_effect=reappear):
            result = self.run_sync(confirm_deletions=[self.relative(path) for path in paths[:2]])
        self.assertEqual((result.deleted, result.deletion_guard), (0, "ABSENCE_RECHECK_CHANGED"))
        self.assertEqual([self.state(path)[0] for path in paths[:2]], ["MISSING", "MISSING"])
        self.assertEqual(len(self.snapshots()["daily"]), 5)

    def test_empty_clean_root_records_complete_and_search_reports_no_exclusions(self):
        result = self.run_sync()
        self.assertTrue(result.completed)
        self.assertEqual((result.indexed, result.failed, result.missing), (0, 0, 0))
        coverage = search(self.db, "", before=date(2026, 11, 22))
        self.assertFalse(coverage.incomplete)
        self.assertEqual(coverage.last_full_success, result.last_attempt)

from contextlib import closing
from pathlib import Path
import sqlite3
import sys
from tempfile import TemporaryDirectory
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "40_scripts" / "py_scripts"))

from mdh_db.storage import (
    DatabaseIntegrityError,
    SchemaVersionError,
    check_integrity,
    create_database,
    open_database,
    transaction,
)

HASH = "a" * 64
SOURCE = "2026/2026-11/2026-11-22.md"
DAY = "2026-11-22"


class StorageTests(unittest.TestCase):
    def setUp(self):
        scratch = TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.path = Path(scratch.name) / "I1 スキーマ.sqlite"
        create_database(self.path, root_identity="人工 fixture のルート")

    def seed_snapshot(self, db):
        # Insert the circular references in one transaction. Both are checked at commit.
        db.execute("INSERT INTO daily VALUES (1, ?, ?, ?, ?)", (DAY, SOURCE, HASH, "timestamp"))
        db.execute("""
            INSERT INTO sync_file (source_path, day, status, snapshot_id, observed_hash, observed_at)
            VALUES (?, ?, 'CURRENT', 1, ?, ?)
        """, (SOURCE, DAY, HASH, "timestamp"))
        db.execute("INSERT INTO topic VALUES (1, 10, 100, '作業')")
        db.execute("INSERT INTO topic VALUES (1, 101, 150, '作業')")
        db.execute("""
            INSERT INTO section(daily_id, topic_start, start, stop, level, parent_start, title)
            VALUES (1, 10, 20, 90, 3, NULL, '条件'), (1, 10, 25, 50, 4, 20, '詳細')
        """)
        db.execute("INSERT INTO completion VALUES (1, 151, 200, ?, '分類: 作業', '分類', '作業')", (DAY,))
        db.execute("INSERT INTO completion VALUES (1, 201, 250, ?, '分: 類: 作業', NULL, NULL)", (DAY,))
        db.execute("INSERT INTO search_document VALUES (1, 'topic', 10, '作業', 20, 22, 5, 1, '字📚')")

    def test_schema_identity_tables_and_version_on_read_only_connection(self):
        before = self.path.read_bytes()
        with open_database(self.path) as db:
            self.assertEqual(db.execute("PRAGMA user_version").fetchone(), (1,))
            self.assertEqual(db.execute("PRAGMA foreign_keys").fetchone(), (1,))
            self.assertEqual(db.execute("SELECT root_identity FROM metadata").fetchone(),
                             ("人工 fixture のルート",))
            tables = {name for (name,) in db.execute("SELECT name FROM sqlite_schema WHERE type='table'")}
            self.assertEqual(tables, {"metadata", "daily", "sync_file", "topic", "section",
                                      "completion", "search_document"})
            self.assertEqual(db.execute("PRAGMA index_info('sync_status_day')").fetchall(),
                             [(0, 2, "status"), (1, 1, "day")])
            with self.assertRaises(sqlite3.OperationalError):
                db.execute("DELETE FROM metadata")
            check_integrity(db)
        self.assertEqual(self.path.read_bytes(), before)

    def test_deferred_references_and_search_span_commit_together(self):
        with open_database(self.path, read_only=False) as db:
            with transaction(db, write=True):
                self.seed_snapshot(db)
            self.assertEqual(db.execute("SELECT body FROM searchable").fetchall(), [("字📚",)])
            self.assertEqual(db.execute("SELECT level, stop FROM section ORDER BY level").fetchall(),
                             [(3, 90), (4, 50)])
            self.assertEqual(db.execute("SELECT category, task FROM completion ORDER BY start").fetchall(),
                             [("分類", "作業"), (None, None)])
            check_integrity(db)

    def test_deferred_fk_commit_failure_rolls_back_snapshot_and_metadata(self):
        with open_database(self.path, read_only=False) as db:
            with self.assertRaises(sqlite3.IntegrityError):
                with transaction(db, write=True):
                    self.seed_snapshot(db)
                    db.execute("UPDATE metadata SET last_attempt = 'must roll back'")
                    db.execute("UPDATE sync_file SET observed_hash = ?", ("b" * 64,))
            self.assertFalse(db.in_transaction)
            for table in ("daily", "sync_file", "topic", "section", "completion", "search_document"):
                self.assertEqual(db.execute(f"SELECT COUNT(*) FROM {table}").fetchone(), (0,))
            self.assertEqual(db.execute("SELECT last_attempt FROM metadata").fetchone(), (None,))
            check_integrity(db)

    def test_statement_errors_roll_back_prior_changes_and_preserve_existing_snapshot(self):
        cases = (
            ("INSERT INTO search_document VALUES (1,'invalid',10,'',30,31,1,1,'字')", "CHECK"),
            ("INSERT INTO search_document VALUES (1,'topic',10,'',30,40,1,1,'字')", "CHECK"),
            ("INSERT INTO search_document VALUES (999,'topic',10,'',30,31,1,1,'字')", "FOREIGN KEY"),
            ("INSERT INTO search_document VALUES (1,'topic',10,'',20,21,1,1,'字')", "UNIQUE"),
            ("INSERT INTO daily VALUES (2,'2026-11-22','other.md',lower(hex(zeroblob(32))),'z')", "UNIQUE"),
            ("INSERT INTO daily VALUES (2,'2026-11-23','2026/2026-11/2026-11-22.md',lower(hex(zeroblob(32))),'z')", "UNIQUE"),
            ("INSERT INTO section VALUES (1,101,105,120,3,20,'別Topicの親')", "FOREIGN KEY"),
            ("INSERT INTO section VALUES (1,10,30,40,2,NULL,'H2')", "CHECK"),
            ("INSERT INTO completion VALUES (1,251,260,'2026-11-22','行','分類',NULL)", "CHECK"),
        )
        with open_database(self.path, read_only=False) as db:
            with transaction(db, write=True):
                self.seed_snapshot(db)
            for statement, code in cases:
                with self.subTest(statement=statement):
                    with self.assertRaisesRegex(sqlite3.IntegrityError, code):
                        with transaction(db, write=True):
                            db.execute("UPDATE topic SET title = 'must roll back'")
                            db.execute(statement)
            self.assertEqual(db.execute("SELECT DISTINCT title FROM topic").fetchall(), [("作業",)])
            check_integrity(db)

    def test_deleting_snapshot_and_unlinking_state_in_one_transaction_cascades(self):
        with open_database(self.path, read_only=False) as db:
            with transaction(db, write=True):
                self.seed_snapshot(db)
            with transaction(db, write=True):
                db.execute("UPDATE sync_file SET status='DELETED', snapshot_id=NULL")
                db.execute("DELETE FROM daily WHERE daily_id=1")
            for table in ("daily", "topic", "section", "completion", "search_document"):
                self.assertEqual(db.execute(f"SELECT COUNT(*) FROM {table}").fetchone(), (0,))
            self.assertEqual(db.execute("SELECT status FROM sync_file").fetchone(), ("DELETED",))
            check_integrity(db)

    def test_unrecognized_versions_are_rejected_without_mutation(self):
        for version in (0, 2):
            with self.subTest(version=version):
                path = self.path.with_name(f"version-{version}.sqlite")
                with closing(sqlite3.connect(path)) as db:
                    db.execute("CREATE TABLE marker (payload TEXT)")
                    db.execute(f"PRAGMA user_version = {version}")
                before = path.read_bytes()
                for read_only in (False, True):
                    with self.assertRaises(SchemaVersionError) as error:
                        with open_database(path, read_only=read_only):
                            self.fail("unsupported file must not open")
                    self.assertEqual(error.exception.found, version)
                    self.assertEqual(path.read_bytes(), before)

    def test_existing_file_is_never_recreated_and_open_never_creates_new_file(self):
        before = self.path.read_bytes()
        with self.assertRaises(FileExistsError):
            create_database(self.path, root_identity="別のルート")
        self.assertEqual(self.path.read_bytes(), before)
        missing = self.path.with_name("missing.sqlite")
        for read_only in (False, True):
            with self.assertRaises(sqlite3.OperationalError):
                with open_database(missing, read_only=read_only):
                    self.fail("missing database must not open")
        self.assertFalse(missing.exists())

    def test_integrity_check_detects_preexisting_orphan_without_modifying_database(self):
        with closing(sqlite3.connect(self.path)) as db:
            db.execute("PRAGMA foreign_keys = OFF")
            db.execute("INSERT INTO search_document VALUES (100, 'topic', 0, '', 0, 1, 1, 1, '字')")
            db.commit()
        before = self.path.read_bytes()
        with open_database(self.path) as db:
            with self.assertRaisesRegex(DatabaseIntegrityError, "foreign_key_check failed"):
                check_integrity(db)
        self.assertEqual(self.path.read_bytes(), before)

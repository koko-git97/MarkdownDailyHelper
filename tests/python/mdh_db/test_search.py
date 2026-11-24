from contextlib import closing
from datetime import date
from pathlib import Path
import sqlite3
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parents[2] / "40_scripts" / "py_scripts"
FIXTURES = HERE / "fixtures"
sys.path[:0] = [str(SCRIPTS)]

import mdh_db.search as search_module
from mdh_db.parser import parse_daily
from mdh_db.search import Match, SearchHit, build_search_spans, insert_search_spans, search
from mdh_db.storage import (
    DatabaseIntegrityError, SchemaVersionError, create_database, open_database, transaction,
)

DAY = date(2026, 11, 22)
NOW = "2026-11-22T01:00:00+00:00"
HASH = "a" * 64
RAW = (FIXTURES / "search_groups.md").read_bytes()


class SearchTests(unittest.TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name) / "検索.sqlite"
        create_database(self.path, root_identity="artificial")

    def seed(self, day, raw=RAW, state="CURRENT"):
        filename = day.strftime("%Y/%Y-%m/%Y-%m-%d.md")
        with open_database(self.path, read_only=False) as db, transaction(db, write=True):
            daily_id = db.execute("""
                INSERT INTO daily(day, source_path, source_hash, indexed_at) VALUES (?, ?, ?, ?)
            """, (day.isoformat(), filename, HASH, NOW)).lastrowid
            db.execute("""
                INSERT INTO sync_file(source_path, day, status, snapshot_id, observed_hash, observed_at)
                VALUES (?, ?, ?, ?, ?, ?)
            """, (filename, day.isoformat(), state, daily_id, HASH, NOW))
            insert_search_spans(db, daily_id, build_search_spans(parse_daily(raw)))
            db.execute("UPDATE metadata SET last_full_success=?, last_attempt=?", (NOW, NOW))
        return daily_id

    def test_groups_terms_dates_and_match_positions(self):
        self.seed(DAY)
        def hit(kind, start, title, *matches):
            return SearchHit(DAY.isoformat(), "2026/2026-11/2026-11-22.md", kind, start,
                             title, "CURRENT", HASH, tuple(Match(*m, m[0]) for m in matches))

        joined = (hit("topic", 87, "閲覧室", ("図書", 94, 96, 9, 1), ("CSV", 97, 100, 9, 4)),)
        for query, expected in (
            ("図書 CSV", joined), ("図書\u3000CSV", joined), ("図書\u00a0CSV", joined),
            ("閲覧室", (
                hit("topic", 87, "閲覧室", ("閲覧室", 90, 93, 8, 4)),
                hit("topic", 121, "別の閲覧室", ("閲覧室", 126, 129, 10, 6)),
            )),
            ("前文専用語", (hit("preamble", 81, "", ("前文専用語", 81, 86, 7, 1)),)),
            ("参照直下語", (hit("daily_segment", 136, "参考", ("参照直下語", 141, 146, 13, 1)),)),
            ("場外記録語 場外詳細語", (hit("daily_segment", 147, "紙の資料",
                                    ("場外記録語", 155, 160, 15, 1), ("場外詳細語", 168, 173, 17, 1)),)),
            ("仕事 完了一号", (hit("completion", 276, "仕事", ("仕事", 296, 298, 25, 21),
                                  ("完了一号", 300, 304, 25, 25)),)),
            ("手入力予定", (hit("daily_segment", 174, "", ("手入力予定", 184, 189, 19, 1)),)),
            ("100%", (hit("topic", 87, "閲覧室", ("100%", 101, 105, 9, 8)),)),
            ("書誌_", (hit("topic", 87, "閲覧室", ("書誌_", 106, 109, 9, 13)),)),
            ("\\", (hit("topic", 87, "閲覧室", ("\\", 112, 113, 9, 19)),)),
            (r"C:\書誌_100%", (hit("topic", 87, "閲覧室", (r"C:\書誌_100%", 110, 120, 9, 17)),)),
            ("図書 分類専用語", ()), ("前文専用語 CSV", ()), ("参照直下語 場外記録語", ()),
            ("完了一号 完了二号", ()), ("自動予定除外", ()), ("2026-11-21.md", ()),
            ("検索除外メタデータ", ()), ("100_", ()), ("\u3000", ()),
        ):
            with self.subTest(query=query):
                self.assertEqual(search(self.path, query, after=DAY, before=DAY).hits, expected)
        self.assertFalse(search(self.path, "図書", before=date(2026, 11, 21)).hits)

    def test_spans_are_independent_and_preserve_multiline_code_and_literal_links(self):
        text = (
            "[← 2026-11-21](2026-11-21.md)\n\n[手書き](参考.md)\n\n"
            "# ✅ やったこと\n## 分割\n前側\n"
            "<!-- MDH:APPOINTMENTS:START -->\n自動予定\n<!-- MDH:APPOINTMENTS:END -->\n"
            "後側\n\n~~~md\nコード字\n別行字\n~~~\n"
        )
        raw = text.encode()
        self.seed(DAY, raw)
        daily = parse_daily(raw)
        topic = [span for span in build_search_spans(daily) if span.kind == "topic"]
        self.assertEqual(len(topic), 2)
        self.assertLess(topic[0].stop, topic[1].start)
        for span in topic:
            self.assertEqual(span.body, text[span.start:span.stop])
        self.assertFalse(search(self.path, "前側後側").hits)
        self.assertFalse(search(self.path, "自動予定").hits)
        self.assertFalse(search(self.path, "2026-11-21.md").hits)
        self.assertEqual(len(search(self.path, "手書き").hits), 1)
        self.assertEqual(len(search(self.path, "前側 後側 コード字 別行字").hits), 1)

    def test_original_positions_recover_lf_and_bom_crlf_text(self):
        raw = (FIXTURES / "new_daily_crlf.md").read_bytes()
        lf = raw.decode("utf-8-sig").replace("\r\n", "\n").encode()
        self.seed(DAY, raw)
        self.seed(date(2026, 11, 21), lf)
        for hit, original, bom in zip(search(self.path, "絵文字📚").hits, (raw, lf), (3, 0), strict=True):
            text = original.decode("utf-8-sig")
            match, = hit.matches
            expected = text.index("絵文字📚")
            self.assertEqual((match.start, match.stop), (expected, expected + len(match.term)))
            start = bom + len(text[:match.start].encode())
            stop = bom + len(text[:match.stop].encode())
            self.assertEqual(original[start:stop].decode(), match.excerpt)
            self.assertEqual(match.line, text[:expected].count("\n") + 1)
            self.assertEqual(match.column, expected - text.rindex("\n", 0, expected))

    def test_repeated_term_returns_first_position_on_each_matching_line(self):
        text = "# ✅ やったこと\r\n## 書誌\r\n図書 図書\r\n未一致\r\n👩‍🏫 図書\r\n"
        self.seed(DAY, b"\xef\xbb\xbf" + text.encode())
        hit, = search(self.path, "図書 図書").hits
        self.assertEqual([(m.line, m.column) for m in hit.matches], [(3, 1), (5, 5)])
        self.assertEqual([text[m.start:m.stop] for m in hit.matches], ["図書", "図書"])

    def test_status_filters_and_unmatched_coverage(self):
        self.seed(DAY)
        self.seed(date(2026, 11, 21), state="STALE")
        self.seed(date(2026, 11, 20), state="MISSING")
        with open_database(self.path, read_only=False) as db, transaction(db, write=True):
            db.executemany("""
                INSERT INTO sync_file(source_path, day, status, observed_at) VALUES (?, ?, ?, ?)
            """, [("bad.md", None, "INVALID", NOW), ("past.md", "2026-11-19", "INVALID", NOW),
                  ("deleted.md", "2026-11-18", "DELETED", NOW)])
        result = search(self.path, "図書")
        self.assertEqual([hit.status for hit in result.hits], ["CURRENT"])
        self.assertEqual(result.excluded, {"STALE": 1, "INVALID": 2, "MISSING": 1, "DELETED": 1})
        self.assertEqual(result.last_full_success, NOW)
        self.assertTrue(result.incomplete)
        result = search(self.path, "図書", include_stale=True, after=date(2026, 11, 21), before=DAY)
        self.assertEqual([hit.status for hit in result.hits], ["CURRENT", "STALE"])
        self.assertTrue(result.hits[1].from_last_good_snapshot)
        self.assertEqual(result.hits[1].snapshot_hash, HASH)
        self.assertEqual((result.stale_in_scope, result.undated_invalid), (1, 1))
        self.assertEqual(result.excluded, {"INVALID": 0, "MISSING": 0, "DELETED": 0})
        result = search(self.path, "\u3000", after=DAY)
        self.assertEqual(result.hits, ())
        self.assertEqual(result.undated_invalid, 1)
        self.assertTrue(result.incomplete)

    def test_no_success_and_failed_later_attempt_are_not_reported_as_complete(self):
        initial = search(self.path, "未登録")
        self.assertIsNone(initial.last_full_success)
        self.assertTrue(initial.incomplete)
        self.seed(DAY)
        with open_database(self.path, read_only=False) as db, transaction(db, write=True):
            db.execute("UPDATE metadata SET last_attempt='later'")
        result = search(self.path, "一致なし")
        self.assertEqual((result.hits, result.last_attempt, result.last_full_success), ((), "later", NOW))
        self.assertTrue(result.incomplete)

    def test_database_is_not_mutated_and_invalid_databases_fail(self):
        self.seed(DAY)
        before = self.path.read_bytes()
        for query in ("図書", "不存在", "  "):
            search(self.path, query)
        self.assertEqual(self.path.read_bytes(), before)
        missing = self.path.with_name("missing.sqlite")
        with self.assertRaises(sqlite3.OperationalError):
            search(missing, "")
        self.assertFalse(missing.exists())
        uninitialized = self.path.with_name("empty.sqlite")
        uninitialized.touch()
        with self.assertRaises(SchemaVersionError):
            search(uninitialized, "")
        corrupt = self.path.with_name("corrupt.sqlite")
        corrupt.write_bytes(b"invalid sqlite bytes")
        with self.assertRaises(sqlite3.DatabaseError):
            search(corrupt, "")
        with closing(sqlite3.connect(self.path)) as db:
            db.execute("PRAGMA user_version=2")
        with self.assertRaises(SchemaVersionError):
            search(self.path, "")

    def test_invalid_snapshot_metadata_is_rejected_even_for_blank_query(self):
        with open_database(self.path, read_only=False) as db, transaction(db, write=True):
            db.execute("DELETE FROM metadata")
        with self.assertRaises(DatabaseIntegrityError):
            search(self.path, "")

    def test_hits_and_coverage_share_snapshot_during_concurrent_commit(self):
        self.seed(DAY)
        original = search_module._matched_groups
        with open_database(self.path, read_only=False) as writer:
            writer.execute("PRAGMA journal_mode=WAL").fetchone()

            def commit_between_queries(*args):
                with transaction(writer, write=True):
                    writer.execute("UPDATE sync_file SET status='STALE'")
                return original(*args)

            with patch.object(search_module, "_matched_groups", side_effect=commit_between_queries):
                result = search(self.path, "図書")
            self.assertEqual([hit.status for hit in result.hits], ["CURRENT"])
            self.assertEqual(result.excluded["STALE"], 0)
            self.assertFalse(search(self.path, "図書").hits)
            self.assertEqual(search(self.path, "").excluded["STALE"], 1)

    def test_insert_requires_transaction_and_rolls_back_with_caller(self):
        daily_id = self.seed(DAY)
        with open_database(self.path, read_only=False) as db:
            count, = db.execute("SELECT COUNT(*) FROM search_document").fetchone()
            spans = tuple(build_search_spans(parse_daily(RAW)))
            with self.assertRaises(ValueError):
                insert_search_spans(db, daily_id, spans)
            with self.assertRaises(sqlite3.IntegrityError):
                with transaction(db, write=True):
                    db.execute("DELETE FROM search_document")
                    insert_search_spans(db, daily_id, (*spans, spans[0]))
            self.assertEqual(db.execute("SELECT COUNT(*) FROM search_document").fetchone(), (count,))

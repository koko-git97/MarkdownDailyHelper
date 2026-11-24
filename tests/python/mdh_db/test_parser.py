from datetime import date
from hashlib import sha256
from pathlib import Path
import sys
import unittest

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parents[2] / "40_scripts" / "py_scripts"
FIXTURES = HERE / "fixtures"
sys.path[:0] = [str(SCRIPTS)]

from mdh_db.parser import Completion, Heading, ParseError, Section, Span, Topic, parse_daily


class ParserTests(unittest.TestCase):
    def test_fixture_structure_and_diagnostics_without_writes(self):
        expected = {
            "legacy_bounded.md": (1, 3),
            "legacy_no_boundary.md": ("LEGACY_WORKLOG_AMBIGUOUS", 4),
            "nested_examples.md": (1, 0), "new_daily_crlf.md": (2, 1),
            "search_groups.md": (2, 2),
            "legacy_reserved_peer.md": ("LEGACY_WORKLOG_AMBIGUOUS", 5),
            "sync_invalid.md": ("LEGACY_WORKLOG_AMBIGUOUS", 3),
            "worklog_missing.md": ("WORKLOG_MISSING", None),
        }
        self.assertEqual({p.name for p in FIXTURES.glob("*.md")}, set(expected))
        for name, (first, second) in expected.items():
            with self.subTest(fixture=name):
                fixture = FIXTURES / name
                raw = fixture.read_bytes()
                if isinstance(first, str):
                    with self.assertRaises(ParseError) as actual:
                        parse_daily(raw)
                    self.assertEqual(actual.exception.code, first)
                    if second is None:
                        self.assertIsNone(actual.exception.span)
                        self.assertEqual(str(actual.exception), first)
                    else:
                        self.assertEqual((actual.exception.span.line, actual.exception.span.column), (second, 1))
                        self.assertEqual(str(actual.exception), f"{first} at line {second}")
                else:
                    daily = parse_daily(raw)
                    self.assertEqual((len(daily.topics), len(daily.completions)), (first, second))
                    self.assertEqual(daily.source.text, raw.decode("utf-8-sig"))
                self.assertEqual(sha256(fixture.read_bytes()).digest(), sha256(raw).digest())

    def test_legacy_bounded_worklog_has_exact_topics_and_completion_records(self):
        daily = parse_daily((FIXTURES / "legacy_bounded.md").read_bytes())
        self.assertEqual(daily.worklog, Heading(2, "✅ やったこと", Span(7, 18, 2, 1)))
        self.assertEqual(daily.worklog_span, Span(7, 186, 2, 1))
        self.assertEqual(daily.preamble, Span(18, 27, 3, 1))
        self.assertEqual(daily.topics, (
            Topic(Heading(2, "夜空の模型", Span(27, 36, 5, 1)), Span(27, 61, 5, 1), (
                Section(Heading(3, "星の形", Span(45, 53, 7, 1)), Span(45, 61, 7, 1), 27),
            )),
        ))
        self.assertEqual(daily.completions, (
            Completion(date(2024, 2, 29), "工作: 光る紙を選ぶ", "工作", "光る紙を選ぶ", Span(84, 115, 11, 1)),
            Completion(date(2026, 11, 22), "道具:紙ばさみ: 刃を拭く", "道具:紙ばさみ", "刃を拭く", Span(115, 149, 12, 1)),
            Completion(date(2026, 11, 22), "図案: 星: 月: 色を決める", None, None, Span(149, 185, 13, 1)),
        ))

    def test_unbounded_legacy_worklog_reports_exact_ambiguous_heading(self):
        with self.assertRaises(ParseError) as failure:
            parse_daily((FIXTURES / "legacy_no_boundary.md").read_bytes())
        self.assertEqual(failure.exception.code, "LEGACY_WORKLOG_AMBIGUOUS")
        self.assertEqual(failure.exception.span, Span(27, 35, 4, 1))

    def test_offsets_are_bom_free_codepoints_and_preserve_original_line_endings(self):
        normalized = (FIXTURES / "new_daily_crlf.md").read_bytes().decode("utf-8-sig").replace("\r\n", "\n")
        for newline in ("\n", "\r\n"):
            for bom in (False, True):
                with self.subTest(newline=newline, bom=bom):
                    text = normalized.replace("\n", newline)
                    prefix = b"\xef\xbb\xbf" if bom else b""
                    raw = prefix + text.encode()
                    daily = parse_daily(raw)
                    self.assertEqual(daily.source.text, text)
                    self.assertEqual(daily.source.has_bom, bom)
                    span = daily.completions[0].span
                    line = f"- [TODO 2026-11-22] 図書: 整理📚{newline}"
                    offset = text.index(line)
                    self.assertEqual((span.start, span.end, span.line, span.column),
                                     (offset, offset + len(line), text[:offset].count(newline) + 1, 1))
                    start = len(prefix) + len(text[:span.start].encode())
                    stop = len(prefix) + len(text[:span.end].encode())
                    self.assertEqual(raw[start:stop], line.encode())
                    self.assertEqual(daily.completions[0].task, "整理📚")

    def test_invalid_utf8_and_ambiguity_are_reported_without_partial_results(self):
        for raw, code in (
            (b"\xff", "INVALID_UTF8"),
            ("---\nnote: 本文候補\n---\n# ✅ やったこと\n".encode(), "FRONT_MATTER_AMBIGUOUS"),
            ("# 作業ログ\n## ✅ やったこと\n## 曖昧な見出し".encode(), "LEGACY_WORKLOG_AMBIGUOUS"),
        ):
            with self.subTest(code=code):
                with self.assertRaises(ParseError) as failure:
                    parse_daily(raw)
                self.assertEqual(failure.exception.code, code)

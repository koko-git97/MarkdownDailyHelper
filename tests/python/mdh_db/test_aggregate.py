import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from urllib.parse import unquote, urlsplit

from markdown_it import MarkdownIt

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "40_scripts" / "py_scripts"))

from mdh_db.aggregate import AggregateError, collect_entries, conflicts, filename_part, relative_url, split_type
from mdh_db.aggregate_cli import _arguments, _execute
from mdh_db.aggregate_output import generated_bytes, publish


class AggregateTests(unittest.TestCase):
    def setUp(self):
        scratch = TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.daily = self.root / "Daily"
        self.daily.mkdir()
        self.aggregate = self.root / "Aggregate"
        self.config = self.root / "config.json"
        self.set_concepts({})

    def set_concepts(self, concepts):
        self.config.write_text(json.dumps({"daily": {"keep": True}, "concepts": concepts}), encoding="utf-8")

    def write_daily(self, day, text):
        path = self.daily / day[:4] / day[:7] / (day + ".md")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(("# ✅ やったこと\n\n" + text).encode("utf-8"))
        return path

    def command(self, operation, *options):
        args = _arguments([
            operation, f"--config={self.config}", f"--daily-root={self.daily}",
            f"--aggregate-root={self.aggregate}", f"--cwd={self.root}", *options,
        ])
        results = {"registered": False, "warnings": [], "concepts": [], "markdown": None, "index_changed": False}
        issues = []
        code = _execute(args, results, issues)
        return code, results, issues

    def test_type_prefix_and_windows_output_names(self):
        for title, result in [
            ("[Meeting]図書整理", ("Meeting", "図書整理")),
            ("[Meeting] 図書整理", ("Meeting", "図書整理")),
            ("[ Meeting ] 図書整理", ("Meeting", "図書整理")),
            ("[] 図書整理", (None, "[] 図書整理")),
            ("[  ] 図書整理", (None, "[  ] 図書整理")),
            ("[Meeting][Review] 図書整理", ("Meeting", "[Review] 図書整理")),
            ("図書整理", (None, "図書整理")),
        ]:
            self.assertEqual(split_type(title), result)
        self.assertEqual(filename_part("Ｐｙｔｈｏｎ　基礎", suffix=".md"), "Python_基礎.md")
        self.assertEqual(filename_part("C/C++ 入門", suffix=".md"), "C_C++_入門.md")
        self.assertEqual(filename_part("ＣＯＮ", suffix=".md"), "_CON.md")
        for value in ("..", " / ", "a" * 256):
            with self.assertRaises(AggregateError):
                filename_part(value)
        self.assertEqual(conflicts({"a": ("x.md",), "b": ("X.MD", "y.md"), "c": ("INDEX.MD",)}),
                         {"a", "b", "c"})

    def test_root_readme_is_excluded_without_relaxing_daily_validation(self):
        readme = self.daily / "README.md"
        text = "# ✅ やったこと\n## 架空の図書整理\n"
        readme.write_text(text, encoding="utf-8")
        self.assertEqual(collect_entries(self.daily), [])
        self.assertEqual(readme.read_text(encoding="utf-8"), text)
        path = self.write_daily("2026-11-23", "## 図書\n")
        self.assertEqual([entry.path for entry in collect_entries(self.daily)], [path])
        (path.parent / "README.md").write_text(text, encoding="utf-8")
        with self.assertRaisesRegex(AggregateError, "Invalid Daily filename"):
            collect_entries(self.daily)

    def test_title_matching_group_order_and_duplicate_headings(self):
        self.set_concepts({"Python": {"keywords": ["API", "ｐｙｔｈｏｎ"], "category": "開発"}, "API": {}})
        self.write_daily("2026-11-01", "## [Meeting] API\n\nold\n")
        self.write_daily("2026-11-23", "## [Review] ＰＹＴＨＯＮ API\n\nfirst\n"
                         "\n## [review] ＰＹＴＨＯＮ API\n\nsecond\n\n## Without match\nPython API\n")
        code, report, issues = self.command("run")
        self.assertEqual((code, issues), (0, []))
        self.assertEqual([item["topics"] for item in report["concepts"]], [3, 3])
        output = self.aggregate / "開発" / "Python.md"
        body = output.read_text(encoding="utf-8")
        self.assertEqual(body.count("### 2026-11-23｜ＰＹＴＨＯＮ API"), 2)
        self.assertLess(body.index("## Review"), body.index("## Meeting"))
        self.assertLess(body.index("first"), body.index("second"))
        self.assertNotIn("Without match", body)
        snapshot, timestamp = output.read_bytes(), output.stat().st_mtime_ns
        self.assertFalse(self.command("run")[1]["concepts"][0]["changed"])
        self.assertEqual((output.read_bytes(), output.stat().st_mtime_ns), (snapshot, timestamp))

    def test_markdown_uses_token_boundaries_and_rebases_paths(self):
        path = self.write_daily("2026-11-23", """## [ Meeting ]Test

### H3
#### H4
##### H5
###### H6
[Link](asset.txt "title") ![Picture](picture.png) [Anchor](#section) [Web](https://example.org) [Ref][id]

`[code](keep.md)`

```md
### Unchanged
![code](keep.png)
```

<a href="keep.md">HTML</a>

[id]: ref.md
""")
        (path.parent / "asset.txt").write_text("fixture")
        source = path.read_bytes()
        code, report, _ = self.command("reverse", "--concept=Test", "--type= meeting ")
        self.assertEqual(code, 0)
        text = report["markdown"]
        for fragment in ("#### H3", "##### H4", "###### H5", "###### H6",
                         '](Daily/2026/2026-11/asset.txt "title")',
                         "](Daily/2026/2026-11/picture.png)", "](Daily/2026/2026-11/2026-11-23.md#section)",
                         "](https://example.org)", "[Ref][id]", "`[code](keep.md)`",
                         "### Unchanged\n![code](keep.png)", '<a href="keep.md">'):
            self.assertIn(fragment, text)
        self.assertNotIn("## [ Meeting ]Test", text)
        self.assertTrue(any("H6" in warning for warning in report["warnings"]))
        self.assertTrue(any("missing" in warning for warning in report["warnings"]))
        self.assertTrue(any("Reference" in warning for warning in report["warnings"]))
        self.assertFalse(self.aggregate.exists())
        self.assertEqual(path.read_bytes(), source)

    def test_unregistered_export_and_zero_topic_file_protection(self):
        self.write_daily("2026-11-23", "## Alpha\nbody\n")
        self.assertEqual(self.command("reverse", "--concept=Alpha")[0], 0)
        standard = self.aggregate / "Alpha.md"
        before = standard.read_bytes()
        export = self.root / "report.md"
        self.assertEqual(self.command("reverse", "--concept=Alpha", f"--output={export}")[0], 0)
        self.assertEqual(standard.read_bytes(), before)
        self.assertIn(b'"kind":"export"', export.read_bytes())
        self.set_concepts({"No match": {}})
        self.assertEqual(self.command("run")[0], 0)
        index = (self.aggregate / "index.md").read_text(encoding="utf-8")
        self.assertIn("No match（0件・—）", index)
        self.assertNotIn("[No match]", index)
        self.assertIsNone(self.command("reverse", "--concept=No match")[1]["concepts"][0]["path"])
        self.assertFalse((self.aggregate / "No_match.md").exists())
        self.assertFalse(json.loads(self.config.read_bytes())["concepts"].get("Alpha"))

    def test_generated_local_links_keep_unicode_and_escape_path_delimiters(self):
        self.daily = self.root / "日報 (資料)#100%"
        self.daily.mkdir()
        self.set_concepts({"書誌": {"category": "開発 (設計)#100%"}})
        path = self.write_daily(
            "2026-11-23",
            "## 書誌\n\n[資料](<資料 (第1版) %23100%25.txt?mode=raw#節>)\n\n"
            "![画像](画像%20%28書誌%29%23100%25.png)\n",
        )
        (path.parent / "資料 (第1版) #100%.txt").write_text("fixture", encoding="utf-8")
        (path.parent / "画像 (書誌)#100%.png").touch()
        code, report, issues = self.command("run")
        self.assertEqual((code, issues, report["warnings"]), (0, [], []))

        index = (self.aggregate / "index.md").read_text(encoding="utf-8")
        self.assertIn("[書誌](開発_%28設計%29%23100%25/書誌.md)", index)
        topic = (self.aggregate / "開発_(設計)#100%" / "書誌.md").read_text(encoding="utf-8")
        prefix = "../../日報%20%28資料%29%23100%25/2026/2026-11/"
        self.assertIn(f"[元の日報]({prefix}2026-11-23.md)", topic)
        self.assertIn(f"[資料](<{prefix}資料%20%28第1版%29%20%23100%25.txt?mode=raw#節>)", topic)
        self.assertIn(f"![画像]({prefix}画像%20%28書誌%29%23100%25.png)", topic)

    def test_reparsed_query_and_anchor_keep_their_meaning(self):
        path = self.write_daily(
            "2026-11-23",
            r"## [Meeting] 書誌" "\n\n"
            r"[資料](<資料 (版) %23%25.txt?q=a\)b%2F%3F&next=1#節\)>) "
            r"[アンカー](#a\)b) ![画像](画像.png?size=a\(b#img\))" "\n",
        )
        asset = path.parent / "資料 (版) #%.txt"
        image = path.parent / "画像.png"
        asset.touch()
        image.touch()
        code, report, issues = self.command("reverse", "--concept=書誌", "--type=Meeting")
        self.assertEqual((code, issues, report["warnings"]), (0, [], []))
        tokens = [child for token in MarkdownIt().parse(report["markdown"]) for child in token.children or []]
        source_tokens = [child for token in MarkdownIt().parse(path.read_text(encoding="utf-8"))
                         for child in token.children or []]
        original = [urlsplit(child.attrGet("href") or child.attrGet("src"))
                    for child in source_tokens if child.type in ("link_open", "image")]
        converted = [urlsplit(child.attrGet("href") or child.attrGet("src"))
                     for child in tokens if child.type in ("link_open", "image")][1:]
        self.assertEqual(len(converted), len(original))
        for before, after, target in zip(original, converted, (asset, path, image)):
            self.assertEqual((after.query, after.fragment), (before.query, before.fragment))
            self.assertEqual((self.root / unquote(after.path)).resolve(), target.resolve())
        self.assertIn("資料%20%28版%29%20%23%25.txt", report["markdown"])
        # Windows forbids '?' in real filenames. Check the encoding on a lexical path.
        self.assertEqual(relative_url(self.root / "資料?.md", self.root), "資料%3F.md")

    def test_multiline_setext_topic_renders_as_one_heading(self):
        path = self.write_daily("2026-11-23", "[Meeting] First line\nSecond line\n-----------\n\nBody\n")
        original = path.read_bytes()
        code, report, issues = self.command("reverse", "--concept=Second line", "--type=Meeting")
        self.assertEqual((code, issues), (0, []))
        tokens = MarkdownIt().parse(report["markdown"])
        headings = [tokens[index + 1].content for index, token in enumerate(tokens)
                    if token.type == "heading_open" and token.tag == "h3"]
        self.assertEqual(headings, ["2026-11-23｜First line Second line"])
        self.assertNotIn("\nSecond line\n", report["markdown"])
        self.assertEqual(path.read_bytes(), original)

    def test_partial_failures_keep_index_and_skip_all_collisions(self):
        self.write_daily("2026-11-23", "## A/ Test Python Alpha\nbody\n")
        self.aggregate.mkdir()
        index = self.aggregate / "index.md"
        index.write_bytes(b"manual index")
        self.set_concepts({"Python": {}, "ＰＹＴＨＯＮ": {}, "Alpha": {}, "index": {}})
        code, report, issues = self.command("run")
        self.assertEqual((code, len(issues)), (1, 3))
        self.assertEqual([item["name"] for item in report["concepts"]], ["Alpha"])
        self.assertFalse((self.aggregate / "Python.md").exists())
        self.assertEqual(index.read_bytes(), b"manual index")
        self.set_concepts({"Alpha": {}})
        self.assertEqual(self.command("run")[2][0]["code"], "INDEX_FAILED")
        self.assertEqual(index.read_bytes(), b"manual index")

    def test_individual_replace_failure_does_not_publish_index(self):
        self.set_concepts({"Alpha": {}, "Beta": {}})
        self.write_daily("2026-11-23", "## Alpha\nfirst\n\n## Beta\nfirst\n")
        self.assertEqual(self.command("run")[0], 0)
        alpha = self.aggregate / "Alpha.md"
        index = self.aggregate / "index.md"
        before = (alpha.read_bytes(), index.read_bytes())
        self.write_daily("2026-11-23", "## Alpha\nsecond\n\n## Beta\nsecond\n")
        original_replace = os.replace

        def fail_alpha(source, target):
            if Path(target).name == "Alpha.md":
                raise PermissionError("simulated locked output")
            return original_replace(source, target)

        with patch("mdh_db.aggregate_output.os.replace", side_effect=fail_alpha):
            code, report, issues = self.command("run")
        self.assertEqual(code, 1)
        self.assertIn("simulated locked output", issues[0]["message"])
        self.assertEqual([item["name"] for item in report["concepts"]], ["Beta"])
        self.assertIn(b"second", (self.aggregate / "Beta.md").read_bytes())
        self.assertEqual((alpha.read_bytes(), index.read_bytes()), before)
        self.assertFalse(list(self.aggregate.glob(".mdh-*.tmp")))

    def test_bad_inputs_leave_every_output_unchanged(self):
        self.set_concepts({"Alpha": {}})
        self.write_daily("2026-11-01", "## Alpha\nbody\n")
        self.assertEqual(self.command("run")[0], 0)
        before = {path.name: path.read_bytes() for path in self.aggregate.glob("*.md")}
        valid_location = self.daily / "2026" / "2026-11"
        cases = [
            (self.daily / "2026-11-30.md", b"bad hierarchy"),
            (valid_location / "2026-11-31.md", b"bad date"),
            (valid_location / "2026-11-30.md", b"\xff"),
            (valid_location / "2026-11-30.md", b"missing worklog"),
        ]
        for path, data in cases:
            with self.subTest(path=path, data=data):
                path.write_bytes(data)
                with self.assertRaisesRegex(AggregateError, path.name.replace(".", r"\.")):
                    self.command("run")
                path.unlink()
                self.assertEqual({p.name: p.read_bytes() for p in self.aggregate.glob("*.md")}, before)
        for bad in ("{", '{"concepts":[]}', '{"concepts":{"A":{"keywords":[2]}}}'):
            self.config.write_text(bad)
            with self.assertRaises(ValueError):
                self.command("run")
            self.assertEqual({p.name: p.read_bytes() for p in self.aggregate.glob("*.md")}, before)

    def test_registration_is_saved_before_collecting_and_preserves_existing_settings(self):
        self.write_daily("2026-11-23", "## Other\nbody\n")
        code, report, _ = self.command("reverse", "--concept=Alpha", "--register")
        self.assertEqual(code, 0)
        self.assertTrue(report["registered"])
        self.assertEqual(json.loads(self.config.read_bytes()),
                         {"daily": {"keep": True}, "concepts": {"Alpha": {"keywords": []}}})
        before = self.config.read_bytes()
        self.assertFalse(self.command("reverse", "--concept=Alpha", "--register")[1]["registered"])
        self.assertEqual(self.config.read_bytes(), before)
        (self.daily / "2026-11-30.md").write_bytes(b"bad hierarchy")
        with self.assertRaises(AggregateError):
            self.command("reverse", "--concept=Beta", "--register")
        self.assertIn("Beta", json.loads(self.config.read_bytes())["concepts"])
        self.assertFalse(self.aggregate.exists())
        with self.assertRaises(ValueError):
            self.command("reverse", "--concept=Bad", "--register", "--type=Meeting")

    def test_registration_preserves_json_number_tokens_and_unrelated_settings(self):
        self.write_daily("2026-11-23", "## Other\nbody\n")
        unrelated = '"ネスト": { "値": [0.123456789123456789, 1e400, 123456789012345678901234567890], "型": [true,null,"1e400"] }'
        for concepts in ("", ', "concepts": {}', ', "c\\u006fncepts": { "既存": { "keywords": ["日本語"] } }'):
            with self.subTest(concepts=concepts):
                original = ('\ufeff{ ' + unrelated + concepts + ' }\r\n').encode("utf-8")
                self.config.write_bytes(original)
                code, report, issues = self.command("reverse", "--concept=追加", "--register")
                self.assertEqual((code, report["registered"], issues), (0, True, []))
                updated = self.config.read_bytes()
                self.assertNotIn(b"Infinity", updated)
                self.assertTrue(updated.startswith(b"\xef\xbb\xbf"))
                self.assertTrue(updated.endswith(b"\r\n"))
                self.assertIn(unrelated.encode(), updated)
                if "既存" in concepts:
                    self.assertIn('"既存": { "keywords": ["日本語"] }'.encode(), updated)
                code, report, issues = self.command("reverse", "--concept=追加", "--register")
                self.assertEqual((code, report["registered"], issues), (0, False, []))
                self.assertEqual(self.config.read_bytes(), updated)

    def test_registration_rejects_invalid_json_without_writing(self):
        for content in (b'{"value":NaN}', b'{"value":Infinity}', b'{"value":-Infinity}', b'{"value":1,}'):
            with self.subTest(content=content):
                self.config.write_bytes(content)
                with self.assertRaises(ValueError):
                    self.command("reverse", "--concept=追加", "--register")
                self.assertEqual(self.config.read_bytes(), content)

    def test_registration_save_failure_stops_before_collection(self):
        before = self.config.read_bytes()
        with patch("mdh_db.aggregate_output.publish", side_effect=OSError("blocked")), \
                patch("mdh_db.aggregate.collect_entries") as collect:
            with self.assertRaisesRegex(OSError, "blocked"):
                self.command("reverse", "--concept=Alpha", "--register")
            collect.assert_not_called()
        self.assertEqual(self.config.read_bytes(), before)
        self.assertFalse(self.aggregate.exists())

    def test_read_failure_and_empty_index(self):
        self.assertEqual(self.command("run")[0], 0)
        index = (self.aggregate / "index.md").read_bytes()
        self.assertNotIn("0件".encode(), index)
        self.set_concepts({"Alpha": {}})
        self.write_daily("2026-11-23", "## Alpha\nbody\n")
        with patch.object(Path, "read_bytes", side_effect=OSError("unreadable")):
            with self.assertRaisesRegex(AggregateError, "2026-11-23.md: unreadable"):
                collect_entries(self.daily)
        self.assertEqual((self.aggregate / "index.md").read_bytes(), index)

    def test_output_ownership_conflicts_and_race_rejection(self):
        path = self.root / "report.md"
        expected = generated_bytes("first\n", "export", "A", "Meeting")
        self.assertTrue(publish(path, expected))
        self.assertFalse(publish(path, expected))
        for different in (
            generated_bytes("new\n", "export", "B", "Meeting"),
            generated_bytes("new\n", "export", "A", "Review"),
            generated_bytes("new\n", "aggregate", "A"),
        ):
            with self.assertRaises(AggregateError):
                publish(path, different)
            self.assertEqual(path.read_bytes(), expected)
        self.assertTrue(publish(path, generated_bytes("changed\n", "export", "A", "ｍｅｅｔｉｎｇ")))
        path.write_bytes(b"manual")
        with self.assertRaises(AggregateError):
            publish(path, expected)
        self.assertEqual(path.read_bytes(), b"manual")
        path.write_bytes(expected)
        with patch("mdh_db.aggregate_output._read_existing", side_effect=(expected, b"changed externally")):
            with self.assertRaisesRegex(AggregateError, "changed before saving"):
                publish(path, generated_bytes("new\n", "export", "A", "Meeting"))
        self.assertEqual(path.read_bytes(), expected)
        self.assertFalse(list(self.root.glob(".mdh-*.tmp")))

    def test_export_protects_daily_and_config_and_aggregate_roots(self):
        daily = self.write_daily("2026-11-23", "## Alpha\nbody\n")
        source, config = daily.read_bytes(), self.config.read_bytes()
        for target in (daily, self.config, self.aggregate / "external.md"):
            code, _, issues = self.command("reverse", "--concept=Alpha", f"--output={target}")
            self.assertEqual(code, 4)
            self.assertIn("Protected output", issues[0]["message"])
        self.assertFalse(self.aggregate.exists())
        self.assertEqual((daily.read_bytes(), self.config.read_bytes()), (source, config))

    def test_export_refuses_a_linked_directory(self):
        self.write_daily("2026-11-23", "## Alpha\nbody\n")
        actual = self.root / "actual"
        actual.mkdir()
        alias = self.root / "alias"
        try:
            alias.symlink_to(actual, target_is_directory=True)
        except OSError as error:
            if os.name != "nt":
                self.skipTest(f"Cannot create directory symlink: {error}")
            # Junctions exercise the Windows reparse-point check without elevation.
            subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(alias), str(actual)],
                           check=True, capture_output=True)
        code, _, issues = self.command("reverse", "--concept=Alpha", f"--output={alias / 'file.md'}")
        self.assertEqual(code, 4)
        self.assertIn("Unsafe output path", issues[0]["message"])
        self.assertFalse(list(actual.iterdir()))

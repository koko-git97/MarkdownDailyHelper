from contextlib import contextmanager
from hashlib import sha256
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import NamedTemporaryFile, TemporaryDirectory
import time
import unittest
from unittest.mock import Mock, patch
from urllib.parse import unquote, urlsplit

from markdown_it import MarkdownIt

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "40_scripts" / "py_scripts"))

from mdh_db import aggregate_output as output
from mdh_db.aggregate import AggregateError, collect_entries, conflicts, filename_part, relative_url, split_type
from mdh_db.aggregate_cli import _arguments, _execute
from mdh_db.aggregate_markdown import render_topics
from mdh_db.aggregate_output import (_canonical_volume_path, _check_spelling, _junction_destination, _location, _physically_within,
                                     _resolve, _writer, generated_bytes, publish)


def volume_alias(path):
    """Get the fixture volume's GUID without altering its mount points."""
    import ctypes
    from ctypes import wintypes

    get_volume = ctypes.WinDLL("kernel32", use_last_error=True).GetVolumeNameForVolumeMountPointW
    get_volume.argtypes = (wintypes.LPCWSTR, wintypes.LPWSTR, wintypes.DWORD)
    get_volume.restype = wintypes.BOOL
    buffer = ctypes.create_unicode_buffer(128)
    if not get_volume(path.anchor, buffer, len(buffer)):
        raise ctypes.WinError(ctypes.get_last_error())
    return Path(buffer.value).joinpath(*path.parts[1:])


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

    def test_table_images_and_links_rebase_without_rewriting_cells(self):
        header = r'| ![Picture](picture.png) | ![Picture](picture.png) |'
        separator = '| :--- | ---: |'
        row = r'| ![A\|B](<picture.png> "title") | [file](notes.txt?q=a\|b#part) |'
        mixed = r'| `![code](keep.png)` ![Picture](picture.png) | ![Web](https://example.org/a.png) |'
        nested = '> ![Picture](picture.png) | Text\n> --- | ---\n> [file](notes.txt) | note'
        fenced = '\n'.join(("~~~md", header, separator, row, "~~~"))
        path = self.write_daily("2026-11-23", "\n".join((
            "## Alpha", "", header, separator, row, mixed, "", nested, "", fenced, "",
        )))
        picture = path.with_name("picture.png")
        notes = path.with_name("notes.txt")
        picture.touch()
        notes.touch()
        original = path.read_bytes()
        self.set_concepts({"Alpha": {}})
        export = self.root / "exports" / "nested" / "report.md"

        for operation, options, output_path in (
            ("run", (), self.aggregate / "Alpha.md"),
            ("reverse", ("--concept=Alpha", f"--output={export}"), export),
        ):
            with self.subTest(operation=operation):
                code, report, issues = self.command(operation, *options)
                self.assertEqual((code, issues), (0, []))
                self.assertEqual(report["warnings"], [])
                image_url = relative_url(picture, output_path.parent)
                notes_url = relative_url(notes, output_path.parent)
                body = output_path.read_text(encoding="utf-8")
                self.assertIn("\n".join((header.replace("picture.png", image_url), separator,
                                         row.replace("picture.png", image_url).replace("notes.txt", notes_url),
                                         mixed.replace("picture.png", image_url))), body)
                self.assertIn(nested.replace("picture.png", image_url).replace("notes.txt", notes_url), body)
                self.assertIn(fenced, body)
        self.assertEqual(path.read_bytes(), original)

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

    @unittest.skipUnless(os.name == "nt", "requires Windows drive paths")
    def test_render_uses_file_uris_for_links_across_windows_drives(self):
        self.daily = self.root / "日報 #100%"
        self.daily.mkdir()
        path = self.write_daily("2026-11-23", "## Alpha\n\n[資料](資料%20%23%25.txt?view=raw#section)\n")
        asset = path.with_name("資料 #%.txt")
        asset.touch()
        drive = "Y" if path.drive.upper() == "Z:" else "Z"
        output = Path(f"{drive}:\\Aggregate")
        warnings = []

        body = render_topics("Alpha", collect_entries(self.daily), output, warnings)

        self.assertEqual(warnings, [])
        for prefix, expected in (("[元の日報](", path), ("[資料](", asset)):
            with self.subTest(prefix=prefix):
                uri = urlsplit(body.split(prefix, 1)[1].split(")", 1)[0])
                self.assertEqual((uri.scheme, uri.netloc), ("file", ""))
                self.assertEqual(Path(unquote(uri.path[1:])), expected)
                self.assertIn("%20%23", uri.path)
                self.assertIn("%25", uri.path)
        self.assertIn("?view=raw#section)", body)

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

    def junction(self, alias, actual):
        subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(alias), str(actual)],
                       check=True, capture_output=True)
        self.addCleanup(lambda: alias.rmdir() if os.path.lexists(alias) else None)

    @unittest.skipUnless(os.name == "nt", "requires Windows GUID paths")
    def test_guid_spelling_and_missing_ancestor_identity(self):
        import stat
        from types import SimpleNamespace

        root = volume_alias(self.root)
        _check_spelling(Path(root.anchor), allow_volume=True)
        final = _canonical_volume_path(root / "missing" / "folder")
        self.assertEqual(_location(final), _location(self.root / "missing" / "folder"))
        for invalid in (root, Path(r"\\?\Volume{bad}\folder"), Path(r"\\server\share\folder"),
                        Path(r"\\?\GLOBALROOT\Device\folder"), Path(r"\\.\C:\folder"),
                        root / ".." / "folder", root / "NUL"):
            with self.subTest(path=invalid), self.assertRaises(AggregateError):
                _check_spelling(invalid, allow_volume=invalid != root)
        self.assertEqual(_location(root / "missing" / "file.md"),
                         _location(self.root / "missing" / "FILE.md"))
        self.assertNotEqual(_location(root / "elsewhere" / "file.md"),
                            _location(self.root / "missing" / "file.md"))
        self.assertTrue(_physically_within(root / "missing" / "file.md", self.root / "missing"))
        self.assertFalse(_physically_within(root / "elsewhere" / "file.md", self.root / "missing"))
        info = SimpleNamespace(st_reparse_tag=stat.IO_REPARSE_TAG_MOUNT_POINT,
                               st_file_attributes=stat.FILE_ATTRIBUTE_DIRECTORY)
        with patch("mdh_db.aggregate_output.os.readlink", return_value=root.anchor):
            self.assertEqual(_junction_destination(self.root / "link", info), Path(root.anchor))
        for invalid in (root.anchor.rstrip("\\"), r"\\?\Volume{bad}\folder",
                        r"\\?\UNC\server\share\folder", r"\\?\GLOBALROOT\Device\folder", r"C:relative"):
            with self.subTest(destination=invalid), patch("mdh_db.aggregate_output.os.readlink", return_value=str(invalid)):
                with self.assertRaises(AggregateError):
                    _junction_destination(self.root / "link", info)
        self.assertEqual(relative_url(root / "file.md", root), "file.md")
        self.assertTrue(relative_url(self.root / "file.md", root).startswith("file:///"))
        with self.assertRaises(AggregateError):
            relative_url(root / "file.md", self.root)
        with patch("mdh_db.aggregate_output._canonical_volume_path", side_effect=PermissionError):
            with self.assertRaises(PermissionError):
                _resolve(root)

    @unittest.skipUnless(os.name == "nt", "requires Windows API bindings")
    def test_canonical_volume_path_windows_api_branches(self):
        import ctypes

        path = self.root / "missing"
        guid = volume_alias(self.root)
        invalid = ctypes.c_void_p(-1).value
        cases = (
            ("DOS", [7], 0, [(4, 0, str(path))], [0], path, None),
            ("GUID fallback", [7], 0, [(0, 3, None), (4, 0, str(guid / path.name))],
             [0, 1], guid / path.name, None),
            ("GUID failure", [7], 0, [(0, 3, None), (0, 3, None)], [0, 1], None, 3),
            ("missing", [invalid, 7], 2, [(4, 0, str(self.root))], [0], path, None),
            ("open denied", [invalid], 5, [], [], None, 5),
            ("query denied", [7], 0, [(0, 5, None)], [0], None, 5),
            ("buffer full", [7], 0, [(32768, 0, None)], [0], None, "too long"),
        )
        for name, handles, open_error, replies, flags, expected, error in cases:
            with self.subTest(case=name):
                kernel = Mock()
                kernel.CreateFileW.side_effect = handles
                responses = iter(replies)

                def final_name(handle, buffer, capacity, mode):
                    size, last_error, value = next(responses)
                    ctypes.set_last_error(last_error)
                    if value is not None:
                        buffer.value = value
                    return size

                kernel.GetFinalPathNameByHandleW.side_effect = final_name
                ctypes.set_last_error(open_error)
                with patch.object(ctypes, "WinDLL", return_value=kernel):
                    if error is None:
                        self.assertEqual(_canonical_volume_path(path), expected)
                    elif error == "too long":
                        with self.assertRaisesRegex(AggregateError, error):
                            _canonical_volume_path(path)
                    else:
                        with self.assertRaises(OSError) as raised:
                            _canonical_volume_path(path)
                        self.assertEqual(raised.exception.winerror, error)
                opened = [call.args[0] for call in kernel.CreateFileW.call_args_list]
                self.assertEqual(opened, [str(item) for item in (path, *path.parents)][:len(handles)])
                self.assertEqual([call.args[3] for call in kernel.GetFinalPathNameByHandleW.call_args_list], flags)
                self.assertEqual([call.args[0] for call in kernel.CloseHandle.call_args_list],
                                 [handle for handle in handles if handle != invalid])

    @unittest.skipUnless(os.name == "nt", "requires Windows path aliases")
    def test_export_rejects_existing_and_missing_daily_paths_through_aliases(self):
        import ctypes
        from ctypes import wintypes

        self.daily = self.root / "Long Daily Directory"
        self.daily.mkdir()
        self.set_concepts({"Alpha": {}})
        daily = self.write_daily("2026-11-23", "## Alpha\nfixture\n")
        before = daily.read_bytes()
        dos = self.root / "DOS"
        guid = self.root / "GUID"
        self.junction(dos, self.daily)
        self.junction(guid, volume_alias(self.daily))
        aliases = [self.daily, Path(str(self.daily).upper()), dos, guid]
        short_name = ctypes.WinDLL("kernel32", use_last_error=True).GetShortPathNameW
        short_name.argtypes = (wintypes.LPCWSTR, wintypes.LPWSTR, wintypes.DWORD)
        short_name.restype = wintypes.DWORD
        buffer = ctypes.create_unicode_buffer(32768)
        size = short_name(str(self.daily), buffer, len(buffer))
        if 0 < size < len(buffer) and Path(buffer.value) != self.daily:
            aliases.append(Path(buffer.value))
        for alias in aliases:
            for relative in (daily.relative_to(self.daily), Path("missing.md")):
                with self.subTest(alias=alias, relative=relative):
                    code, _, issues = self.command("reverse", "--concept=Alpha", f"--output={alias / relative}")
                    self.assertEqual(code, 4)
                    self.assertIn("Protected output", issues[0]["message"])
        self.assertEqual(daily.read_bytes(), before)
        self.assertFalse((self.daily / "missing.md").exists())

    @unittest.skipUnless(os.name == "nt", "requires Windows GUID junctions")
    def test_guid_ancestor_chain_publish_links_and_protection(self):
        actual = self.root / "集約 実体"
        actual.mkdir()
        guid_alias = self.root / "GUID link"
        self.junction(guid_alias, volume_alias(actual))
        self.assertIn("Volume{", os.readlink(guid_alias))
        outer = self.root / "DOS link"
        self.junction(outer, guid_alias)
        self.aggregate = outer / "new" / "inner"
        self.set_concepts({"Alpha": {"category": "Work"}})
        daily = self.write_daily("2026-11-23", "## Alpha\n[asset](asset.txt)\n")
        asset = daily.with_name("asset.txt")
        asset.write_bytes(b"asset")
        original = daily.read_bytes(), self.config.read_bytes(), asset.read_bytes()
        self.assertEqual(self.command("reverse", "--concept=Alpha")[0], 0)
        target = actual / "new" / "inner" / "Work" / "Alpha.md"
        content = target.read_text(encoding="utf-8")
        self.assertIn(relative_url(daily, target.parent), content)
        self.assertIn(relative_url(asset, target.parent), content)
        self.assertNotIn("file:", content)
        self.assertEqual(self.command("run")[0], 0)
        index = target.parent.parent / "index.md"
        self.assertIn("[Alpha](Work/Alpha.md)", index.read_text(encoding="utf-8"))
        self.assertEqual(self.command("reverse", "--concept=Alpha", f"--output={guid_alias / 'export.md'}")[0], 0)

        protected_alias = self.root / "daily alias"
        self.junction(protected_alias, volume_alias(self.daily))
        config_alias = self.root / "config alias"
        self.junction(config_alias, volume_alias(self.config.parent))
        for path in (protected_alias / "blocked.md", config_alias / "config.json",
                     config_alias / "config.template.json", guid_alias / "new" / "inner" / "blocked.md"):
            with self.subTest(path=path):
                code, _, issues = self.command("reverse", "--concept=Alpha", f"--output={path}")
                self.assertEqual(code, 4)
                self.assertIn("Protected output", issues[0]["message"])
        self.assertEqual((daily.read_bytes(), self.config.read_bytes(), asset.read_bytes()), original)
        self.assertFalse((self.daily / "blocked.md").exists())
        self.assertFalse(self.config.with_name("config.template.json").exists())

        self.set_concepts({"Alpha": {"category": "internal"}})
        internal = target.parent.parent / "internal"
        self.junction(internal, volume_alias(actual))
        code, _, issues = self.command("reverse", "--concept=Alpha")
        self.assertEqual(code, 4)
        self.assertIn("at or above", issues[0]["message"])

    @unittest.skipUnless(os.name == "nt", "requires Windows GUID junctions")
    def test_mixed_guid_cycle_and_missing_target_are_rejected(self):
        first = self.root / "first"
        second = self.root / "second"
        self.junction(first, volume_alias(second))
        self.aggregate = first
        self.write_daily("2026-11-23", "## Alpha\nfixture\n")
        code, _, issues = self.command("reverse", "--concept=Alpha")
        self.assertEqual(code, 4)
        self.assertIn("destination is missing", issues[0]["message"])
        self.junction(second, first)
        code, _, issues = self.command("reverse", "--concept=Alpha")
        self.assertEqual(code, 4)
        self.assertIn("circular", issues[0]["message"])

    @unittest.skipUnless(os.name == "nt", "requires Windows GUID paths")
    def test_guid_without_dos_name_keeps_index_links_relative(self):
        actual = self.root / "actual"
        actual.mkdir()
        self.junction(self.aggregate, volume_alias(actual))
        daily = self.write_daily("2026-11-23", "## Alpha\nfixture\n")
        self.set_concepts({"Alpha": {}})
        daily_alias = self.root / "daily alias"
        self.junction(daily_alias, volume_alias(self.daily))
        settings = self.root / "settings alias"
        self.junction(settings, volume_alias(self.config.parent))
        before = daily.read_bytes(), self.config.read_bytes()
        # The real GUID path is usable. Simulate only the absence of a DOS final name.
        with patch("mdh_db.aggregate_output._canonical_volume_path", side_effect=lambda path: path):
            code, _, issues = self.command("run")
            for protected in (daily_alias / "blocked.md", settings / "config.json",
                              settings / "config.template.json", actual / "blocked.md"):
                with self.subTest(protected=protected):
                    failure, _, diagnostics = self.command("reverse", "--concept=Alpha", f"--output={protected}")
                    self.assertEqual(failure, 4)
                    self.assertIn("Protected output", diagnostics[0]["message"])
        self.assertEqual((code, issues), (0, []))
        self.assertEqual((daily.read_bytes(), self.config.read_bytes()), before)
        self.assertFalse((actual / "blocked.md").exists())
        self.assertIn(daily.as_uri(), (actual / "Alpha.md").read_text(encoding="utf-8"))
        self.assertIn("[Alpha](Alpha.md)", (actual / "index.md").read_text(encoding="utf-8"))

    @unittest.skipUnless(os.name == "nt", "requires Windows GUID junctions")
    def test_guid_junction_retarget_before_publish_keeps_original(self):
        old = self.root / "old"
        new = self.root / "new"
        old.mkdir()
        new.mkdir()
        self.junction(self.aggregate, volume_alias(old))
        self.write_daily("2026-11-23", "## Alpha\nold\n")
        self.assertEqual(self.command("reverse", "--concept=Alpha")[0], 0)
        original = (old / "Alpha.md").read_bytes()
        self.write_daily("2026-11-23", "## Alpha\nchanged\n")
        fsync = os.fsync

        def retarget(fd):
            fsync(fd)
            self.aggregate.rmdir()
            self.junction(self.aggregate, volume_alias(new))

        with patch("mdh_db.aggregate_output.os.fsync", side_effect=retarget):
            code, _, issues = self.command("reverse", "--concept=Alpha")
        self.assertEqual(code, 4)
        self.assertIn("Output directory changed", issues[0]["message"])
        self.assertEqual((old / "Alpha.md").read_bytes(), original)
        self.assertEqual(list(old.iterdir()), [old / "Alpha.md"])
        self.assertFalse(list(new.iterdir()))

    @unittest.skipUnless(os.name == "nt", "requires Windows mutexes")
    def test_mutex_blocks_a_separate_process_for_same_output_path(self):
        script = """
import ctypes
from ctypes import wintypes
from pathlib import Path
import sys

sys.path.insert(0, sys.argv[1])
from mdh_db.aggregate_output import _writer

win_dll = ctypes.WinDLL

def observe_wait(*args, **kwargs):
    kernel = win_dll(*args, **kwargs)
    wait = kernel.WaitForSingleObject
    wait.argtypes = (wintypes.HANDLE, wintypes.DWORD)
    wait.restype = wintypes.DWORD

    def observed(handle, timeout):
        result = wait(handle, 0)
        if result == 258:  # WAIT_TIMEOUT: the kernel confirmed contention.
            Path(sys.argv[3]).touch()
            return wait(handle, timeout)
        return result

    kernel.WaitForSingleObject = observed
    return kernel

ctypes.WinDLL = observe_wait
with _writer(Path(sys.argv[2])):
    print("locked", flush=True)
"""
        package = str(Path(__file__).resolve().parents[3] / "40_scripts" / "py_scripts")
        dos = self.root / "lock.md"

        def command(path, marker):
            return [sys.executable, "-B", "-c", script, package, str(path), str(marker)]

        def assert_uncontended(path, label):
            marker = self.root / label
            result = subprocess.run(command(path, marker), capture_output=True, text=True, timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "locked")
            self.assertFalse(marker.exists())

        assert_uncontended(dos, "control")
        key = sha256(str(dos).upper().encode("utf-8")).hexdigest()
        marker = self.root / "waited"
        child = None
        try:
            with output._windows_mutex(key, dos):
                child = subprocess.Popen(command(dos, marker), stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, text=True)
                deadline = time.monotonic() + 8
                while not marker.exists():
                    if child.poll() is not None:
                        stdout, stderr = child.communicate(timeout=2)
                        self.fail(f"Child exited before contention ({child.returncode}): {stdout}{stderr}")
                    if time.monotonic() >= deadline:
                        child.kill()
                        stdout, stderr = child.communicate(timeout=5)
                        self.fail(f"Child did not report kernel contention: {stdout}{stderr}")
                    time.sleep(0.01)
                self.assertIsNone(child.poll())
            stdout, stderr = child.communicate(timeout=8)
            self.assertEqual(child.returncode, 0, stderr)
            self.assertEqual(stdout.strip(), "locked")
        finally:
            if child is not None:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=5)

    def test_export_refuses_a_symbolic_link(self):
        self.write_daily("2026-11-23", "## Alpha\nbody\n")
        actual = self.root / "actual"
        actual.mkdir()
        alias = self.root / "alias"
        try:
            alias.symlink_to(actual, target_is_directory=True)
        except OSError as error:
            self.skipTest(f"Cannot create directory symlink: {error}")
        code, _, issues = self.command("reverse", "--concept=Alpha", f"--output={alias / 'file.md'}")
        self.assertEqual(code, 4)
        self.assertIn("Unsafe output path", issues[0]["message"])
        self.assertFalse(list(actual.iterdir()))

    @unittest.skipUnless(os.name == "nt", "requires Windows junctions")
    def test_junction_root_ancestor_index_export_and_path_lock(self):
        daily = self.write_daily("2026-11-23", "## Alpha\nbody\n")
        self.set_concepts({"Alpha": {}})
        actual = self.root / "物理 ルート"
        actual.mkdir()
        alias = self.root / "論理 ルート"
        self.junction(alias, actual)
        self.aggregate = alias / "集約"
        destination = actual / "集約" / "Alpha.md"
        with patch("mdh_db.aggregate_output._writer", wraps=_writer) as writer:
            self.assertEqual(self.command("reverse", "--concept=Alpha")[0], 0)
            writer.assert_called_once_with(destination)
        self.assertIn(relative_url(daily, destination.parent), destination.read_text(encoding="utf-8"))
        self.aggregate = destination.parent
        with patch("mdh_db.aggregate_output._writer", wraps=_writer) as writer:
            code, report, _ = self.command("reverse", "--concept=Alpha")
            self.assertEqual(code, 0)
            self.assertFalse(report["concepts"][0]["changed"])
            writer.assert_called_once_with(destination)
        self.aggregate = self.root / "集約 別名"
        self.junction(self.aggregate, destination.parent)
        self.assertEqual(self.command("run")[0], 0)
        index = destination.with_name("index.md")
        before = index.read_bytes()
        self.assertIn(b"[Alpha](Alpha.md)", before)
        destination.write_text("manual", encoding="utf-8")
        self.set_concepts({"Alpha": {}, "Empty": {}})
        self.assertEqual(self.command("run")[0], 1)
        self.assertEqual(index.read_bytes(), before)
        self.assertEqual(destination.read_text(encoding="utf-8"), "manual")
        self.assertEqual(self.command("reverse", "--concept=Alpha", f"--output={alias / '報告 書.md'}")[0], 0)
        self.assertTrue((actual / "報告 書.md").is_file())

    @unittest.skipUnless(os.name == "nt", "requires Windows junctions")
    def test_internal_protected_broken_and_circular_junctions(self):
        daily = self.write_daily("2026-11-23", "## Alpha\nbody\n")
        self.aggregate.mkdir()
        inside = self.aggregate / "inside"
        inside.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        self.set_concepts({"Alpha": {"category": "alias"}})
        alias = self.aggregate / "alias"
        for actual in (inside, outside, self.daily):
            with self.subTest(actual=actual):
                self.junction(alias, actual)
                self.assertEqual(self.command("reverse", "--concept=Alpha")[0], 4)
                self.assertFalse((actual / "Alpha.md").exists())
                alias.rmdir()
        for actual in (inside, self.daily):
            link = self.root / "protected"
            self.junction(link, actual)
            self.assertEqual(self.command("reverse", "--concept=Alpha", f"--output={link / 'file.md'}")[0], 4)
            link.rmdir()
        self.junction(self.root / "settings", self.config.parent)
        template = self.config.with_name("config.template.json")
        template.write_bytes(b"settings template")
        before = self.config.read_bytes()
        for protected in (self.config, template):
            code, _, issues = self.command("reverse", "--concept=Alpha",
                                           f"--output={self.root / 'settings' / protected.name}")
            self.assertEqual(code, 4)
            self.assertIn("Protected output", issues[0]["message"])
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(template.read_bytes(), b"settings template")
        self.junction(alias, outside)
        outside.rmdir()
        self.assertEqual(self.command("reverse", "--concept=Alpha", f"--output={alias / 'file.md'}")[0], 4)
        self.junction(outside, alias)
        self.assertEqual(self.command("reverse", "--concept=Alpha", f"--output={alias / 'file.md'}")[0], 4)
        self.assertTrue(daily.is_file())

    @unittest.skipUnless(os.name == "nt", "requires Windows junctions")
    def test_registration_and_retargeting_preserve_existing_files(self):
        self.write_daily("2026-11-23", "## Alpha\nbody\n")
        actual = self.root / "actual"
        other = self.root / "other"
        actual.mkdir()
        other.mkdir()
        self.junction(self.aggregate, actual)
        original_config = self.config
        self.config.rename(actual / "config.json")
        self.config = self.aggregate / "config.json"
        before = self.config.read_bytes()
        with self.assertRaises(AggregateError):
            self.command("reverse", "--concept=Alpha", "--register")
        self.assertEqual(self.config.read_bytes(), before)
        self.config = original_config
        self.config.write_bytes(before)
        self.assertEqual(self.command("reverse", "--concept=Alpha")[0], 0)
        output = actual / "Alpha.md"
        before = output.read_bytes()
        self.write_daily("2026-11-23", "## Alpha\nnew body\n")
        flush = os.fsync

        def retarget(descriptor):
            flush(descriptor)
            self.aggregate.rmdir()
            self.junction(self.aggregate, other)

        with patch("mdh_db.aggregate_output.os.fsync", side_effect=retarget):
            self.assertEqual(self.command("reverse", "--concept=Alpha")[0], 4)
        self.assertEqual(output.read_bytes(), before)
        self.assertFalse(list(actual.glob(".mdh-*.tmp")))
        self.assertFalse(list(other.iterdir()))

    @unittest.skipUnless(os.name == "nt", "requires Windows junctions")
    def test_mdrun_keeps_initial_root_after_first_concept_is_published(self):
        self.write_daily("2026-11-23", "## Alpha\nfirst\n\n## Beta\nsecond\n")
        self.set_concepts({"Alpha": {}, "Beta": {}})
        actual = self.root / "actual"
        other = self.root / "other"
        actual.mkdir()
        other.mkdir()
        self.junction(self.aggregate, actual)
        self.assertEqual(self.command("run")[0], 0)
        index = (actual / "index.md").read_bytes()
        beta = (actual / "Beta.md").read_bytes()
        self.write_daily("2026-11-23", "## Alpha\nupdated first\n\n## Beta\nupdated second\n")

        def retarget_after_publish(path, *args, **kwargs):
            changed = publish(path, *args, **kwargs)
            self.assertEqual(path, actual / "Alpha.md")
            self.aggregate.rmdir()
            self.junction(self.aggregate, other)
            return changed

        with patch("mdh_db.aggregate_output.publish", side_effect=retarget_after_publish):
            code, report, issues = self.command("run")
        self.assertEqual(code, 1)
        self.assertTrue(report["concepts"][0]["changed"])
        self.assertEqual(issues[0]["code"], "CONCEPT_FAILED")
        self.assertEqual((actual / "index.md").read_bytes(), index)
        self.assertEqual((actual / "Beta.md").read_bytes(), beta)
        self.assertFalse(list(other.iterdir()))

    def test_publish_never_overwrites_new_destination_and_cleans_temporary(self):
        path = self.root / "report.md"
        content = generated_bytes("generated\n", "export", "A")
        real_publish = os.rename if os.name == "nt" else os.link

        def create_destination(source, destination):
            path.write_bytes(b"new external file")
            real_publish(source, destination)

        operation = "rename" if os.name == "nt" else "link"
        with patch(f"mdh_db.aggregate_output.os.{operation}", side_effect=create_destination):
            with self.assertRaises(FileExistsError):
                publish(path, content)
        self.assertEqual(path.read_bytes(), b"new external file")
        self.assertFalse(list(self.root.glob(".mdh-*.tmp")))

    def test_publish_rejects_parent_replacement_and_keeps_unrelated_temporary_name(self):
        directory = self.root / "output"
        directory.mkdir()
        moved = self.root / "moved"
        path = directory / "report.md"
        content = generated_bytes("generated\n", "export", "A")
        path.write_bytes(content)

        def replace_parent():
            directory.rename(moved)
            directory.mkdir()
            temporary = next(moved.glob(".mdh-*.tmp"))
            (directory / temporary.name).write_bytes(b"unrelated")

        @contextmanager
        def temporary_file(**kwargs):
            with NamedTemporaryFile(**kwargs) as handle:
                yield handle
            replace_parent()

        with patch("mdh_db.aggregate_output.NamedTemporaryFile", side_effect=temporary_file):
            with self.assertRaisesRegex(AggregateError, "directory changed"):
                publish(path, generated_bytes("updated\n", "export", "A"))
        self.assertEqual((moved / path.name).read_bytes(), content)
        self.assertFalse(path.exists())
        self.assertEqual(next(directory.glob(".mdh-*.tmp")).read_bytes(), b"unrelated")

    def test_reverse_updates_owned_output_without_identity(self):
        self.set_concepts({"Alpha": {}})
        self.write_daily("2026-11-23", "## Alpha\noriginal\n")
        args = ("reverse", "--concept=Alpha")
        self.assertEqual(self.command(*args)[0], 0)
        path = self.aggregate / "Alpha.md"
        original = path.read_bytes()
        self.write_daily("2026-11-23", "## Alpha\nchanged\n")
        inspect = output._inspect
        fstat = os.fstat

        def without_inode(info):
            return os.stat_result((*info[:1], 0, *info[2:]))

        def inspect_without_inode(candidate):
            info, linked = inspect(candidate)
            if candidate == path or candidate.suffix == ".tmp":
                info = without_inode(info)
            return info, linked

        with patch.object(output, "_inspect", side_effect=inspect_without_inode), \
                patch.object(os, "fstat", side_effect=lambda fd: without_inode(fstat(fd))):
            code, _, issues = self.command(*args)
        self.assertEqual((code, issues), (0, []))
        self.assertNotEqual(path.read_bytes(), original)
        self.assertIn(b"changed", path.read_bytes())
        self.assertEqual(list(self.aggregate.iterdir()), [path])

    @unittest.skipUnless(os.name == "nt", "requires Windows drive APIs")
    def test_remote_drive_classification_does_not_block_aggregation(self):
        import ctypes
        from ctypes import wintypes

        self.set_concepts({"Alpha": {}})
        self.write_daily("2026-11-23", "## Alpha\nfixture\n")
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        get_attributes = kernel.GetFileAttributesW
        get_attributes.argtypes = (wintypes.LPCWSTR,)
        get_attributes.restype = wintypes.DWORD

        def attributes(name):
            # Network providers can reject attribute queries on the volume root.
            self.assertNotEqual(Path(name), Path(name).parent)
            return get_attributes(name)

        kernel.GetFileAttributesW = Mock(side_effect=attributes)
        remote = Mock(return_value=4)
        kernel.GetDriveTypeW = remote
        output._windows_attributes.cache_clear()
        self.addCleanup(output._windows_attributes.cache_clear)
        with patch.object(ctypes, "WinDLL", return_value=kernel):
            self.assertEqual(self.command("run")[0], 0)
        remote.assert_not_called()
        self.assertTrue((self.aggregate / "Alpha.md").is_file())
        self.assertTrue((self.aggregate / "index.md").is_file())

    @unittest.skipUnless(os.name == "nt", "requires Windows UNC paths")
    def test_mapped_drive_can_resolve_to_an_internal_unc_path(self):
        mapped = Path(r"Z:\Reports")
        with patch.object(Path, "resolve", return_value=Path(r"\\?\UNC\server\share\Reports")):
            resolved = _resolve(mapped)
        self.assertEqual(resolved, Path(r"\\server\share\Reports"))
        _check_spelling(resolved, allow_unc=True)
        with self.assertRaises(AggregateError):
            _check_spelling(resolved)
        with self.assertRaises(AggregateError):
            _check_spelling(Path(r"\\.\C:\Reports"), allow_unc=True)

    def test_quicknotes_and_configured_todo_are_protected_even_with_generated_metadata(self):
        self.write_daily("2026-11-23", "## Alpha\nfixture\n")
        notes = self.root / "Notes"
        notes.mkdir()
        todo = self.root / "custom-todo.md"
        original = generated_bytes("original\n", "export", "Alpha")
        targets = [notes / "note.md", todo]
        if os.name == "nt":
            alias = self.root / "Notes alias"
            self.junction(alias, notes)
            targets.append(alias / "note.md")
        for target in targets:
            target.write_bytes(original)
            code, _, issues = self.command("reverse", "--concept=Alpha", f"--output={target}",
                                           f"--quicknotes-root={notes}", f"--todo-file={todo}")
            self.assertEqual(code, 4)
            self.assertIn("Protected output path", issues[0]["message"])
            self.assertEqual(target.read_bytes(), original)

    def test_reverse_keeps_replacement_when_temporary_inode_is_unavailable(self):
        self.set_concepts({"Alpha": {}})
        self.write_daily("2026-11-23", "## Alpha\noriginal\n")
        args = ("reverse", "--concept=Alpha")
        self.assertEqual(self.command(*args)[0], 0)
        path = self.aggregate / "Alpha.md"
        original = path.read_bytes()
        self.write_daily("2026-11-23", "## Alpha\nchanged\n")
        fstat = os.fstat
        inspect = output._inspect
        temporary = None

        @contextmanager
        def replace_after_close(**kwargs):
            nonlocal temporary
            with NamedTemporaryFile(**kwargs) as handle:
                temporary = Path(handle.name)
                try:
                    yield handle
                finally:
                    handle.close()
                    temporary.rename(self.aggregate / "displaced.tmp")
                    temporary.write_bytes(b"unrelated replacement")

        def zero_inode(info):
            return os.stat_result((*info[:1], 0, *info[2:]))

        def inspect_without_inode(candidate):
            info, linked = inspect(candidate)
            return (zero_inode(info) if candidate == temporary else info), linked

        for issue_at_creation in (True, False):
            with self.subTest(issue_at_creation=issue_at_creation):
                with patch.object(output, "NamedTemporaryFile", replace_after_close), patch.object(
                        output, "_inspect", side_effect=inspect_without_inode), patch.object(
                        output.os, "fstat", side_effect=lambda fd: zero_inode(fstat(fd)) if issue_at_creation else fstat(fd)):
                    if issue_at_creation:
                        with patch.object(output.os, "fsync", side_effect=OSError("injected write interruption")):
                            with self.assertLogs(output.__name__, level="WARNING") as logs:
                                code, _, issues = self.command(*args)
                        self.assertIn("injected write interruption", issues[0]["message"])
                        self.assertIn("Temporary output retained", logs.output[0])
                    else:
                        with self.assertLogs(output.__name__, level="WARNING") as logs:
                            code, _, issues = self.command(*args)
                        self.assertIn("Temporary output retained", logs.output[0])
                        self.assertIn("Output changed", issues[0]["message"])
                self.assertEqual(code, 4)
                self.assertEqual(path.read_bytes(), original)
                self.assertEqual(temporary.read_bytes(), b"unrelated replacement")
                self.assertTrue((self.aggregate / "displaced.tmp").is_file())
                temporary.unlink()
                (self.aggregate / "displaced.tmp").unlink()

    def test_reverse_creates_output_with_unidentifiable_existing_ancestor(self):
        self.write_daily("2026-11-23", "## Alpha\nfixture\n")
        ancestor = self.root / "existing"
        ancestor.mkdir()
        path = ancestor / "missing" / "report.md"
        inspect = output._inspect

        def inspect_without_inode(candidate):
            info, linked = inspect(candidate)
            if candidate == ancestor:
                info = os.stat_result((*info[:1], 0, *info[2:]))
            return info, linked

        with patch.object(output, "_inspect", side_effect=inspect_without_inode):
            code, _, issues = self.command("reverse", "--concept=Alpha", f"--output={path}")
        self.assertEqual((code, issues), (0, []))
        self.assertIn(b"fixture", path.read_bytes())

    def test_hard_link_and_temporary_write_failure_preserve_original(self):
        path = self.root / "report.md"
        content = generated_bytes("generated\n", "export", "A")
        updated = generated_bytes("updated\n", "export", "A")
        path.write_bytes(content)
        alias = self.root / "alias.md"
        os.link(path, alias)
        with self.assertRaisesRegex(AggregateError, "single regular file"):
            publish(path, updated)
        self.assertEqual(alias.read_bytes(), content)
        alias.unlink()
        with patch("mdh_db.aggregate_output.os.fsync", side_effect=OSError("flush failed")):
            with self.assertRaisesRegex(OSError, "flush failed"):
                publish(path, updated)
        self.assertEqual(path.read_bytes(), content)
        self.assertFalse(list(self.root.glob(".mdh-*.tmp")))

    @unittest.skipUnless(os.name == "nt", "requires Windows reparse attributes")
    def test_unknown_reparse_attributes_are_rejected_even_when_lstat_looks_normal(self):
        from stat import FILE_ATTRIBUTE_REPARSE_POINT
        from mdh_db.aggregate_output import _windows_attributes

        self.write_daily("2026-11-23", "## Alpha\nbody\n")
        directory = self.root / "unknown"
        directory.mkdir()
        attributes = _windows_attributes()

        def inspect(path):
            value = attributes(path)
            return value | FILE_ATTRIBUTE_REPARSE_POINT if path == directory else value

        with patch("mdh_db.aggregate_output._windows_attributes", return_value=inspect):
            code, _, issues = self.command("reverse", "--concept=Alpha", f"--output={directory / 'file.md'}")
        self.assertEqual(code, 4)
        self.assertIn("reparse point", issues[0]["message"])
        self.assertFalse(list(directory.iterdir()))

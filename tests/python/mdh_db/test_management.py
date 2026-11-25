import json
from pathlib import Path
import sys
from unittest import TestCase
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "40_scripts" / "py_scripts"))

from mdh_db.aggregate import collect_entries
from mdh_db.management_cli import _arguments, _concepts, _types
import test_aggregate


class ManagementTests(TestCase):
    def setUp(self):
        fixture = test_aggregate.AggregateTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.fixture = fixture
        self.config = fixture.config
        self.daily = fixture.daily

    def test_concept_definitions_and_counts_use_aggregate_rules(self):
        diagnostics = []
        fixture = self.fixture
        fixture.set_concepts({"Alpha": {"keywords": ["ＡＬＰＨＡ", "Database"]},
                              "alpha": {"category": "Other", "keywords": ["missing"]},
                              "Beta": {"keywords": ["Database"]}, "Missing": {}})
        fixture.write_daily("2026-11-23", "## [Meeting] ALPHA Database\n## [Alpha] title\n")
        args = _arguments(["concept", f"--config={self.config}", f"--daily-root={self.daily}"])
        with patch("mdh_db.aggregate.collect_entries", side_effect=AssertionError("unexpected scan")):
            result = _concepts(args, diagnostics)
        self.assertEqual(result["registered_count"], 4)
        self.assertNotIn("topic_count", result["concepts"][0])
        self.assertEqual(result["concepts"][1]["category"], "Other")
        args.count = True
        with patch("mdh_db.aggregate.collect_entries", wraps=collect_entries) as scan:
            result = _concepts(args, diagnostics)
            scan.assert_called_once_with(self.daily)
        self.assertEqual([c["topic_count"] for c in result["concepts"]], [1, 1, 1, 0])
        (self.daily / "invalid.md").write_bytes(b"bad")
        result = _concepts(args, diagnostics)
        self.assertEqual(result["registered_count"], 4)
        self.assertEqual([c["topic_count"] for c in result["concepts"]], [None] * 4)
        self.assertEqual(diagnostics[0]["code"], "DAILY_FAILED")

    def test_types_normalize_group_and_preserve_unclassified_identity(self):
        args = _arguments(["type", f"--daily-root={self.daily}"])
        self.assertEqual(_types(args)["types"], [])
        fixture = self.fixture
        fixture.write_daily("2026-11-23", "## [Meeting] A\n## [Ｍｅｅｔｉｎｇ] B\n## [meeting] C\n"
                            "## [Unclassified] D\n## E\n~~~md\n## [Fake] Ignored\n~~~\n")
        result = _types(args)
        self.assertEqual(result["total_topics"], 5)
        self.assertEqual([(item["name"], item["key"], item["topic_count"]) for item in result["types"]],
                         [("Meeting", "meeting", 3), ("Unclassified", "unclassified", 1), (None, None, 1)])
        (self.daily / "invalid.md").write_bytes(b"bad")
        with self.assertRaisesRegex(ValueError, "Invalid Daily"):
            _types(args)

    def test_empty_and_invalid_concept_configuration(self):
        args = _arguments(["concept", f"--config={self.config}"])
        self.assertEqual(_concepts(args, []), {"registered_count": 0, "concepts": []})
        self.config.write_text(json.dumps({"concepts": {"Alpha": {"keywords": "wrong"}}}))
        with self.assertRaisesRegex(ValueError, "string array"):
            _concepts(args, [])

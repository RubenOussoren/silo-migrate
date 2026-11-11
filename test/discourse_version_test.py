"""Run python3 -I -B test/discourse_version_test.py (no services or network)."""
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("discourse_version", ROOT / "bin/discourse_version.py")
versions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(versions)
CASES = json.loads((ROOT / "test/fixtures/discourse-versions.json").read_text())


class DiscourseVersionTest(unittest.TestCase):
    def test_versions(self):
        for case in CASES["versions"]:
            with self.subTest(case=case):
                parsed = versions.parse(case["value"])
                if case["canonical"] is None:
                    self.assertIsNone(parsed)
                else:
                    self.assertEqual(case["canonical"], parsed["canonical"])
                    self.assertEqual(case["track"], parsed["track"])
                    self.assertEqual(case["canonical"].split("-")[0].split(".beta")[0].split(".rc")[0], parsed["release"])

    def test_huge_decimal_is_refused_without_integer_conversion(self):
        self.assertIsNone(versions.parse("3.4." + "9" * 5000))
        self.assertIsNone(versions.parse("3.4.0-beta" + "9" * 5000))

    def test_backups(self):
        for case in CASES["backups"]:
            with self.subTest(case=case):
                parsed = versions.backup(case["name"], extension=case["extension"])
                if case.get("invalid"):
                    self.assertIsNone(parsed)
                else:
                    self.assertEqual({"discourse_version": case["canonical"], "schema_version": case["schema"]}, parsed)
                    # Keep legacy callers' search/group contracts.
                    match = versions.backup_pattern(case["extension"]).search(case["name"])
                    self.assertEqual(case["schema"], match[2])

    def test_comparison(self):
        for left, right, expected in CASES["comparisons"]:
            with self.subTest(left=left, right=right):
                a, b = versions.parse(left)["numeric"], versions.parse(right)["numeric"]
                self.assertEqual(expected, (a > b) - (a < b))


if __name__ == "__main__":
    unittest.main()

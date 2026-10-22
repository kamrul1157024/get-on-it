"""Tests for the getonit-planner skill. Standard library only.

Run: python3 -m unittest discover -s skill/tests -v
"""

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent / "skills" / "getonit-planner"
SCRIPTS = SKILL / "scripts"
EXAMPLES = sorted((SKILL / "examples").glob("*.json"))

try:
    import jsonschema  # noqa: F401
    MODES = [[], ["--no-jsonschema"]]
except ImportError:
    MODES = [["--no-jsonschema"]]


def run_validate(path, *flags):
    proc = subprocess.run([sys.executable, "-I", str(SCRIPTS / "validate.py"), str(path), *flags],
                          capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ExamplesTest(unittest.TestCase):
    def test_there_are_examples(self):
        names = {p.name for p in EXAMPLES}
        self.assertIn("course-cs229.getonit.json", names)
        self.assertIn("custom-template-bundle.getonit.json", names)
        self.assertGreaterEqual(len(names), 6)

    def test_examples_are_valid(self):
        for flags in MODES:
            for path in EXAMPLES:
                with self.subTest(example=path.name, flags=flags):
                    code, out = run_validate(path, *flags)
                    self.assertEqual(code, 0, out)
                    self.assertNotIn("warning:", out)

    def test_file_extension(self):
        for path in EXAMPLES:
            self.assertTrue(path.name.endswith(".getonit.json"), path.name)


class BrokenDocsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def example(self, name):
        return json.loads((SKILL / "examples" / name).read_text(encoding="utf-8"))

    def assert_fails(self, doc, expected_path):
        path = Path(self.tmp.name) / "broken.json"
        path.write_text(doc if isinstance(doc, str) else json.dumps(doc), encoding="utf-8")
        for flags in MODES:
            with self.subTest(flags=flags, expected=expected_path):
                code, out = run_validate(path, *flags)
                self.assertEqual(code, 1, out)
                self.assertIn(f"error: {expected_path}", out)

    def test_video_without_id(self):
        doc = self.example("course-cs229.getonit.json")
        doc["data"]["items"][3] = {"id": "lec-04", "kind": "video", "title": "Lecture 4"}
        self.assert_fails(doc, "data.items[3].videoId: required")

    def test_bad_id_and_template_ref(self):
        doc = self.example("habit-water.getonit.json")
        doc["id"] = "Drink Water"
        self.assert_fails(doc, "id:")
        doc = self.example("habit-water.getonit.json")
        doc["template"] = "habit"
        self.assert_fails(doc, "template:")

    def test_bad_date_and_http_link(self):
        doc = self.example("book-deep-work-pdf.getonit.json")
        doc["deadline"] = "15/12/2026"
        self.assert_fails(doc, "deadline:")
        doc = self.example("book-deep-work-pdf.getonit.json")
        doc["data"]["source"] = {"kind": "url", "url": "http://example.com/book.pdf"}
        self.assert_fails(doc, "data.source.url:")

    def test_count_habit_needs_target(self):
        doc = self.example("habit-water.getonit.json")
        del doc["data"]["target"]
        self.assert_fails(doc, "data.target: required")

    def test_unknown_component_in_custom_template(self):
        doc = self.example("custom-template-bundle.getonit.json")
        children = doc["documents"][0]["surfaces"]["screen"]["children"]
        children.append({"type": "rep_tracker"})
        self.assert_fails(doc, f"documents[0].surfaces.screen.children[{len(children) - 1}].type:")

    def test_custom_template_data_is_checked(self):
        doc = self.example("custom-template-bundle.getonit.json")
        del doc["documents"][1]["data"]["practiceUrl"]
        self.assert_fails(doc, "documents[1].data.practiceUrl: required")

    def test_reminders_and_typos(self):
        doc = self.example("habit-water.getonit.json")
        doc["reminders"] = {"preset": "loud", "time": "7pm"}
        self.assert_fails(doc, "reminders.preset:")
        doc = self.example("habit-water.getonit.json")
        doc["deadlnie"] = "2026-12-01"
        self.assert_fails(doc, "deadlnie: unknown field")

    def test_tree_too_deep(self):
        doc = self.example("custom-template-bundle.getonit.json")
        node = {"type": "text", "value": "deep"}
        for _ in range(25):
            node = {"type": "column", "children": [node]}
        doc["documents"][0]["surfaces"]["screen"] = node
        self.assert_fails(doc, "documents[0].surfaces.screen")

    def test_not_json(self):
        self.assert_fails("{nope", "(root): not valid JSON")


class SyncTest(unittest.TestCase):
    def test_schemas_match_templates(self):
        proc = subprocess.run([sys.executable, "-I", str(SCRIPTS / "sync_schemas.py"), "--check"],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


class PlaylistTitlesTest(unittest.TestCase):
    TITLES = [
        "Stanford CS229: Machine Learning Lecture 1 - Andrew Ng (Autumn 2018)",
        "Stanford CS229: Machine Learning - Linear Regression and Gradient Descent |  Lecture 2 (Autumn 2018)",
        "Locally Weighted & Logistic Regression | Stanford CS229: Machine Learning - Lecture 3 (Autumn 2018)",
        "Lecture 5 - GDA & Naive Bayes | Stanford CS229: Machine Learning Andrew Ng (Autumn 2018)",
        "Discussion Section: Learning Theory | Stanford CS229: Machine Learning (Autumn 2018)",
        "Lecture 14 - EM Algorithm & Factor Analysis | Stanford CS229: Machine Learning Andrew Ng -Autumn2018",
        "RL Debugging and Diagnostics | Stanford CS229: Machine Learning Andrew Ng - Lecture 20 (Autumn 2018)",
    ]
    PLAYLIST = "Stanford CS229: Machine Learning led by Andrew Ng | Autumn 2018"

    def test_items_from_titles(self):
        mod = load_module("playlist_to_items")
        entries = [{"id": f"vid{i:08d}", "title": t, "duration": 4500.4} for i, t in enumerate(self.TITLES)]
        noise = mod.frequent_words(self.TITLES, self.PLAYLIST)
        items = mod.build_items(copy.deepcopy(entries), 3, noise)
        self.assertEqual([i["title"] for i in items], [
            "Lecture 1",
            "Lecture 2: Linear Regression and Gradient Descent",
            "Lecture 3: Locally Weighted & Logistic Regression",
            "Lecture 5: GDA & Naive Bayes",
            "Discussion Section: Learning Theory",
            "Lecture 14: EM Algorithm & Factor Analysis",
            "Lecture 20: RL Debugging and Diagnostics",
        ])
        self.assertEqual([i["id"] for i in items][:4], ["lec-01", "lec-02", "lec-03", "lec-05"])
        self.assertEqual(items[4]["id"], "discussion-section-learning-theory")
        self.assertEqual([i["week"] for i in items], [1, 1, 1, 2, 2, 2, 3])
        self.assertTrue(all(i["durationSec"] == 4500 and i["kind"] == "video" for i in items))


if __name__ == "__main__":
    unittest.main()

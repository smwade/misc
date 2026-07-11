import argparse
import importlib.machinery
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def load_sw():
    loader = importlib.machinery.SourceFileLoader("sw_module", str(Path(__file__).with_name("sw")))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


sw = load_sw()


class SwTests(unittest.TestCase):
    def test_normalize_public_path(self):
        self.assertEqual(sw.normalize_public_path("demo.html"), "/demo.html")
        self.assertEqual(sw.normalize_public_path("/demo.html"), "/demo.html")
        with self.assertRaises(sw.SwError):
            sw.normalize_public_path("../demo.html")

    def test_project_name_validation(self):
        self.assertEqual(sw.validate_name("particle-lab"), "particle-lab")
        with self.assertRaises(sw.SwError):
            sw.validate_name("Particle Lab")

    def test_collect_single_file_project(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "guide.html").write_text("<h1>Guide</h1>")
            (root / "notes.txt").write_text("private notes")
            config = {"output": ".", "include": ["*.html"]}
            output, files = sw.collect_files(root, config)
            self.assertEqual(output, root.resolve())
            self.assertEqual(files, ["guide.html"])

    def test_init_single_html_aliases_sibling_pages(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "guide.html").write_text("<a href='details.html'>Details</a>")
            (root / "details.html").write_text("<h1>Details</h1>")
            original = Path.cwd()
            try:
                import os

                os.chdir(root)
                args = argparse.Namespace(
                    source="guide.html",
                    name="guide",
                    url=None,
                    entry=None,
                    install="",
                    build="",
                    force=False,
                )
                _project_root, config = sw.init_project(args)
            finally:
                os.chdir(original)
            self.assertEqual(config["aliases"]["/guide.html"], "guide.html")
            self.assertEqual(config["aliases"]["/details.html"], "details.html")
            self.assertEqual(json.loads((root / ".sw.json").read_text()), config)


if __name__ == "__main__":
    unittest.main()

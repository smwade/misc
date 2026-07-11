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

    def test_html_title(self):
        with tempfile.TemporaryDirectory() as temp:
            page = Path(temp) / "sample-page.html"
            page.write_text("<title>  Sample &amp; Useful\nPage </title>")
            self.assertEqual(sw.html_title(page), "Sample & Useful Page")

    def test_catalog_pages_are_sorted(self):
        registries = [
            {"pages": [{"title": "Zulu", "project": "food", "url": "/z"}]},
            {"pages": [{"title": "Alpha", "project": "art", "url": "/a"}]},
        ]
        self.assertEqual([page["title"] for page in sw.catalog_pages(registries)], ["Alpha", "Zulu"])

    def test_collect_single_file_project(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "guide.html").write_text("<h1>Guide</h1>")
            (root / "notes.txt").write_text("private notes")
            config = {"output": ".", "include": ["*.html"]}
            output, files = sw.collect_files(root, config)
            self.assertEqual(output, root.resolve())
            self.assertEqual(files, ["guide.html"])

    def test_collect_root_output_excludes_publisher_checkout(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "index.html").write_text("<h1>Site</h1>")
            (root / ".sw-tool").mkdir()
            (root / ".sw-tool" / "README.md").write_text("publisher")
            config = {"output": ".", "include": ["**/*"]}
            _output, files = sw.collect_files(root, config)
            self.assertEqual(files, ["index.html"])

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
            self.assertEqual(config["primary"], "/guide.html")
            self.assertEqual(json.loads((root / ".sw.json").read_text()), config)


if __name__ == "__main__":
    unittest.main()

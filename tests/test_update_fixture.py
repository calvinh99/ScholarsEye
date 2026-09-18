"""Fixture safety: the local test feed must never expose keys or unrelated files."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / "support" / "serve_updates.py"
spec = importlib.util.spec_from_file_location("serve_updates", SCRIPT)
fixture_server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_server)


class UpdateFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "fixture.json").write_text('{}')
        (self.root / "keys").mkdir()
        (self.root / "keys/private-seed.b64").write_text('TEST-ONLY')
        for scenario in fixture_server.SCENARIOS:
            folder = self.root / "server" / scenario
            folder.mkdir(parents=True)
            (folder / "appcast.xml").write_text(scenario)
            (folder / "ScholarsEye-0.3.1.zip").write_bytes(b'ZIP')
        fixture_server.set_scenario(self.root, "good")

    def tearDown(self):
        self.temporary.cleanup()

    def test_scenario_switch_selects_only_prepared_public_files(self):
        for scenario in fixture_server.SCENARIOS[:-1]:
            fixture_server.set_scenario(self.root, scenario)
            path = fixture_server.resolve_request(self.root, "/appcast.xml?cache=123")
            self.assertEqual(path.read_text(), scenario)
        self.assertEqual(fixture_server.resolve_request(self.root, "/ScholarsEye-0.3.1.zip").read_bytes(), b'ZIP')

    def test_private_files_directories_and_traversal_are_not_exposed(self):
        for request in ["/", "/keys/private-seed.b64", "/../keys/private-seed.b64",
                        "/%2E%2E%2Fkeys%2Fprivate-seed.b64", "/private-seed.b64",
                        "/../fixture.json", "/.hidden.xml", "/appcast.xml/more",
                        "/..\\keys\\private-seed.b64", "/missing.xml"]:
            with self.subTest(request=request):
                self.assertIsNone(fixture_server.resolve_request(self.root, request))

    def test_symlink_cannot_escape_the_public_folder(self):
        (self.root / "server/good/stolen.xml").symlink_to(self.root / "keys/private-seed.b64")
        self.assertIsNone(fixture_server.resolve_request(self.root, "/stolen.xml"))

    def test_unavailable_scenario_exposes_no_files(self):
        fixture_server.set_scenario(self.root, "unavailable")
        self.assertIsNone(fixture_server.resolve_request(self.root, "/appcast.xml"))

    def test_unknown_state_is_explicit_failure(self):
        with self.assertRaises(ValueError):
            fixture_server.set_scenario(self.root, "../keys")
        (self.root / "scenario.txt").write_text('../keys')
        with self.assertRaises(ValueError):
            fixture_server.resolve_request(self.root, "/appcast.xml")


if __name__ == "__main__":
    unittest.main()

"""Offline checks for classifier installation and asset pins."""

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from classifier_fixture import build_model
from fetch_landmark_models import ROOT, read_manifest
from prepare_models import install_classifier


class SetupChecks(unittest.TestCase):
    def test_owned_fixture_matches_published_pin(self):
        pin = json.loads((ROOT / "tools/model-assets.json").read_text())["fixture"]
        data = build_model()
        self.assertEqual(len(data), pin["bytes"])
        self.assertEqual(hashlib.sha256(data).hexdigest(), pin["sha256"])

    def test_landmark_manifest_remains_valid(self):
        self.assertEqual(len(read_manifest(ROOT / "tools/model-assets.json")), 2)

    def test_classifier_integrity_and_repeated_install(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            source = root / "source.tflite"
            data = b"independent classifier installation fixture"
            source.write_bytes(data)
            destination = root / "models"
            destination.mkdir()
            pin = {"filename": "classifier.tflite", "bytes": len(data),
                   "sha256": hashlib.sha256(data).hexdigest()}
            install_classifier(source, destination, pin)
            target = destination / pin["filename"]
            self.assertEqual(target.read_bytes(), data)
            inode = target.stat().st_ino
            install_classifier(source, destination, pin)
            self.assertEqual(target.stat().st_ino, inode)
            source.write_bytes(b"x" * len(data))
            with self.assertRaises(ValueError):
                install_classifier(source, destination, pin)
            self.assertEqual(target.read_bytes(), data)
            self.assertEqual(list(destination.iterdir()), [target])


if __name__ == "__main__":
    unittest.main()

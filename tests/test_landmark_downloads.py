"""Exercise streaming/atomic landmark installation using synthetic bytes, with no network."""

import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from fetch_landmark_models import CHUNK_BYTES, ROOT, download_model, read_manifest, verified


class DownloadChecks(unittest.TestCase):
    def setUp(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=ROOT / ".build")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.destination = self.root / "models"
        self.staging = self.root / "staging"
        self.contents = b"nonprivate landmark fixture"
        self.model = {
            "filename": "fixture.task", "bytes": len(self.contents),
            "sha256": hashlib.sha256(self.contents).hexdigest(),
            "url": "https://storage.googleapis.com/fixture.task",
        }

    def install(self, data):
        return download_model(self.model, self.destination, self.staging,
                              open_url=lambda url, timeout: io.BytesIO(data))

    def test_verified_install_and_existing_file_skip_network(self):
        self.install(self.contents)
        self.assertTrue(verified(self.destination / "fixture.task", self.model))
        self.assertEqual(list(self.staging.iterdir()), [])

        def unexpected_network(*args, **kwargs):
            self.fail("A verified existing file triggered a download")

        download_model(self.model, self.destination, self.staging, open_url=unexpected_network)

    def test_bad_download_preserves_existing_file_and_removes_staging(self):
        self.destination.mkdir()
        target = self.destination / "fixture.task"
        target.write_bytes(b"preserve previous file")
        for bad in [b"short", b"x" * len(self.contents), self.contents + b"excess"]:
            with self.subTest(download=bad):
                with self.assertRaises(ValueError):
                    self.install(bad)
                self.assertEqual(target.read_bytes(), b"preserve previous file")
                self.assertEqual(list(self.staging.iterdir()), [])

    def test_network_failure_preserves_existing_file(self):
        self.destination.mkdir()
        target = self.destination / "fixture.task"
        target.write_bytes(b"previous")

        def unavailable(*args, **kwargs):
            raise OSError("Synthetic network failure")

        with self.assertRaises(OSError):
            download_model(self.model, self.destination, self.staging, open_url=unavailable)
        self.assertEqual(target.read_bytes(), b"previous")
        self.assertEqual(list(self.staging.iterdir()), [])

    def test_reads_are_bounded_and_final_short_chunk_is_verified(self):
        self.contents = b"x" * (2 * CHUNK_BYTES + 17)
        self.model["bytes"] = len(self.contents)
        self.model["sha256"] = hashlib.sha256(self.contents).hexdigest()

        class BoundedSource(io.BytesIO):
            def read(source, size=-1):
                self.assertGreater(size, 0)
                self.assertLessEqual(size, CHUNK_BYTES)
                return super().read(size)

        download_model(self.model, self.destination, self.staging,
                       open_url=lambda url, timeout: BoundedSource(self.contents))
        self.assertTrue(verified(self.destination / "fixture.task", self.model))

    def test_manifest_rejects_duplicate_names_and_path_traversal(self):
        manifest = self.root / "manifest.json"
        for models in [[self.model, self.model], [dict(self.model, filename="../outside.task")]]:
            manifest.write_text(json.dumps({"schemaVersion": 1, "models": models}))
            with self.assertRaises(ValueError):
                read_manifest(manifest)


if __name__ == "__main__":
    unittest.main()

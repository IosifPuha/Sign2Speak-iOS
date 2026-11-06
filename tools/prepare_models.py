"""Prepare bundled assets without TensorFlow; Gemma downloads inside the app."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

from classifier_fixture import build_model
from fetch_landmark_models import ROOT, download_model, read_manifest, verified


def install_classifier(source, destination, pin):
    source = source.expanduser().resolve()
    if not verified(source, pin):
        raise ValueError("Classifier size/SHA-256 mismatch; expected the pinned reference artifact.")
    target = destination / pin["filename"]
    if source == target.resolve() or verified(target, pin):
        return
    descriptor, name = tempfile.mkstemp(prefix="classifier-", suffix=".partial", dir=destination)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as output, source.open("rb") as contents:
            shutil.copyfileobj(contents, output, length=1024 * 1024)
        if not verified(temporary, pin):
            raise ValueError("Classifier changed while copying; previous installed file retained.")
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true", help="Fetch all pinned recognition models")
    parser.add_argument("--classifier", type=Path, help="A permitted copy of the pinned classifier.tflite")
    parser.add_argument("--download-landmarks", action="store_true", help="Fetch the two pinned Google models")
    parser.add_argument("--verify", action="store_true", help="Read-only check of all bundled assets")
    parser.add_argument("--fixture-only", action="store_true", help="Generate only the owned fixture for offline host tests")
    args = parser.parse_args()
    if args.verify and (args.classifier or args.download_landmarks or args.download or args.fixture_only):
        parser.error("--verify cannot be combined with installation options")
    if args.fixture_only and (args.classifier or args.download_landmarks or args.download):
        parser.error("--fixture-only cannot be combined with model installation options")
    manifest_path = ROOT / "tools/model-assets.json"
    manifest = json.loads(manifest_path.read_text())
    landmarks = read_manifest(manifest_path)
    destination = ROOT / "Sign2Speak/Models"
    pins = landmarks + [manifest["classifier"], manifest["fixture"]]
    try:
        if not args.verify:
            destination.mkdir(parents=True, exist_ok=True)
            if args.classifier:
                install_classifier(args.classifier, destination, manifest["classifier"])
            fixture = destination / manifest["fixture"]["filename"]
            if not verified(fixture, manifest["fixture"]):
                # Owned, deterministic arithmetic fixture, not a trained model.
                data = build_model()
                if (len(data) != manifest["fixture"]["bytes"]
                        or hashlib.sha256(data).hexdigest() != manifest["fixture"]["sha256"]):
                    raise ValueError("Generated fixture does not match its pin")
                fixture.write_bytes(data)
            if args.fixture_only:
                print("Owned diagnostic fixture verified; no trained models downloaded.")
                return 0
            if args.download_landmarks or args.download:
                for pin in landmarks:
                    print(download_model(pin, destination, ROOT / ".build/model-staging"))
            if args.download:
                print(download_model(manifest["classifier"], destination, ROOT / ".build/model-staging"))
        missing = [pin["filename"] for pin in pins if not verified(destination / pin["filename"], pin)]
        if missing:
            print("Missing or mismatched bundled assets: " + ", ".join(missing))
            print("Run python3 tools/prepare_models.py --download, or supply --classifier with --download-landmarks.")
            return 1
        print("All four bundled model assets verified. Gemma will download on first use.")
        return 0
    except (OSError, ValueError) as error:
        print("Asset setup failed: " + str(error))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

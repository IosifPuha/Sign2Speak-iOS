"""Plan or explicitly download the pinned, public landmark models; never copy reference weights."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlparse
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
CHUNK_BYTES = 1024 * 1024


def read_manifest(path):
    manifest = json.loads(path.read_text())
    if manifest.get("schemaVersion") != 1:
        raise ValueError("Unsupported landmark manifest version")
    models = manifest["models"]
    names = set()
    for model in models:
        name = model["filename"]
        parsed = urlparse(model["url"])
        if (Path(name).name != name or not name.endswith(".task") or name in names
                or parsed.scheme != "https" or parsed.netloc != "storage.googleapis.com"
                or not isinstance(model["bytes"], int) or model["bytes"] <= 0
                or not re.fullmatch(r"[0-9a-f]{64}", model["sha256"])):
            raise ValueError("Invalid landmark asset: " + name)
        names.add(name)
    if not models:
        raise ValueError("No landmark assets specified")
    return models


def verified(path, model):
    if not path.is_file() or path.stat().st_size != model["bytes"]:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest() == model["sha256"]


def download_model(model, destination, staging, open_url=urlopen):
    target = destination / model["filename"]
    if verified(target, model):
        return "Already verified: " + model["filename"]
    destination.mkdir(parents=True, exist_ok=True)
    staging.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix="landmark-", suffix=".partial", dir=staging)
    temporary = Path(name)
    try:
        digest = hashlib.sha256()
        count = 0
        with os.fdopen(descriptor, "wb") as output:
            with open_url(model["url"], timeout=30) as source:
                while True:
                    # Read at most one excess byte, even if a server sends a huge file.
                    chunk = source.read(min(CHUNK_BYTES, model["bytes"] - count + 1))
                    if not chunk:
                        break
                    count += len(chunk)
                    if count > model["bytes"]:
                        raise ValueError("Oversized download: " + model["filename"])
                    digest.update(chunk)
                    output.write(chunk)
        if count != model["bytes"] or digest.hexdigest() != model["sha256"]:
            raise ValueError("Size/SHA-256 mismatch: " + model["filename"])
        # Both approved directories are inside this repository on the same volume.
        # Replacement happens only after verification; a failed download keeps the old file.
        os.replace(temporary, target)
        return "Verified and installed: " + model["filename"]
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=ROOT / "tools/model-assets.json")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--download", action="store_true", help="Download only after owner approval")
    mode.add_argument("--verify", action="store_true", help="Check existing files without network or writes")
    args = parser.parse_args()
    destination = ROOT / "Sign2Speak/Models"
    staging = ROOT / ".build/landmark-staging"
    try:
        models = read_manifest(args.manifest)
        for model in models:
            if args.download:
                print(download_model(model, destination, staging))
            elif args.verify:
                if not verified(destination / model["filename"], model):
                    raise ValueError("Missing or invalid asset: " + model["filename"])
                print("Verified: " + model["filename"])
            else:
                print("PLAN: {} ({} bytes)\n  {}\n  -> {}".format(
                    model["filename"], model["bytes"], model["url"], destination / model["filename"]))
        if not args.download and not args.verify:
            print("No downloads or writes. Use --download only after owner approval.")
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()

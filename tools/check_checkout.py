"""Validate source checkout structure and bundled assets without building iOS."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def check_structure():
    assets = json.loads((ROOT / "tools/model-assets.json").read_text())
    model_inputs = {ROOT / "Sign2Speak/Models" / pin["filename"]
                    for pin in assets["models"] + [assets["classifier"], assets["fixture"]]}
    project = ROOT / "Sign2Speak.xcodeproj/project.pbxproj"
    data = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project)])
    project = json.loads(data)
    objects = project["objects"]
    references = {}

    def visit(identifier, directory):
        obj = objects[identifier]
        source = obj.get("sourceTree", "<group>")
        if source == "BUILT_PRODUCTS_DIR":
            return
        base = ROOT if source == "SOURCE_ROOT" else directory
        path = base / obj.get("path", "")
        if obj["isa"] == "PBXGroup":
            for child in obj.get("children", []):
                visit(child, path)
        else:
            references[identifier] = path

    visit(objects[project["rootObject"]]["mainGroup"], ROOT)
    missing = []
    for obj in objects.values():
        if obj["isa"] in ("PBXSourcesBuildPhase", "PBXResourcesBuildPhase"):
            for identifier in obj["files"]:
                ref = objects[identifier]["fileRef"]
                path = references[ref]
                if not path.exists() and path not in model_inputs:
                    missing.append(str(path.relative_to(ROOT)))
        if obj["isa"] == "XCBuildConfiguration" and "baseConfigurationReference" in obj:
            path = references[obj["baseConfigurationReference"]]
            if not path.is_file():
                missing.append(str(path.relative_to(ROOT)))
        if obj["isa"] == "XCLocalSwiftPackageReference":
            if not (ROOT / obj["relativePath"] / "Package.swift").is_file():
                missing.append(obj["relativePath"] + "/Package.swift")
    if missing:
        raise ValueError("Missing project inputs: " + ", ".join(sorted(set(missing))))

    for catalog in (ROOT / "Sign2Speak/Assets.xcassets").rglob("Contents.json"):
        for item in json.loads(catalog.read_text()).get("images", []):
            if "filename" in item and not (catalog.parent / item["filename"]).is_file():
                raise ValueError("Missing catalog image: " + item["filename"])
    ET.parse(ROOT / "Sign2Speak/AppLaunchScreen.storyboard")
    ET.parse(ROOT / "Sign2Speak.xcodeproj/xcshareddata/xcschemes/Sign2Speak.xcscheme")
    lock = ROOT / "Sign2Speak.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    json.loads(lock.read_text())
    package = ROOT / "Packages/TensorFlowLiteSwift"
    provenance = json.loads((package / "PROVENANCE.json").read_text())
    package_manifest = (package / "Package.swift").read_text()
    if provenance["archive"]["sha256"] not in package_manifest or provenance["archive"]["url"] not in package_manifest:
        raise ValueError("Local package binary pin differs from provenance")
    for pin in provenance["sourceFiles"]:
        data = (package / pin["path"]).read_bytes()
        if len(data) != pin["bytes"] or hashlib.sha256(data).hexdigest() != pin["sha256"]:
            raise ValueError("Local package source mismatch: " + pin["path"])
    for name in ("LICENSE", "NOTICE.md"):
        if not (package / name).is_file():
            raise ValueError("Missing package notice: " + name)

    classifier = json.loads((ROOT / "Sign2Speak/Models/reference_classifier_v1.json").read_text())
    if (classifier["modelSHA256"] != assets["classifier"]["sha256"]
            or classifier["modelBytes"] != assets["classifier"]["bytes"]):
        raise ValueError("Setup and runtime classifier pins differ")

    for name in ("README.md", "docs/architecture.md", "THIRD_PARTY_NOTICES.md"):
        document = ROOT / name
        for target in re.findall(r"\]\(([^)]+)\)", document.read_text()):
            if "://" in target or target.startswith("#"):
                continue
            local = target.split("#", 1)[0]
            if local and not (document.parent / local).exists():
                raise ValueError("Broken documentation link in " + name + ": " + target)
    print("Project inputs, images, shared scheme, package pins/sources and documentation links checked.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-only", action="store_true", help="Allow unprovisioned model binaries")
    args = parser.parse_args()
    try:
        check_structure()
        if args.source_only:
            print("Source structure passed. Bundled model binaries still require separate verification.")
            return 0
        return subprocess.call([sys.executable, str(ROOT / "tools/prepare_models.py"), "--verify"])
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, ET.ParseError) as error:
        print("Checkout check failed: " + str(error))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

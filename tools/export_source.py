"""Export the lean public source selection without staging, committing or uploading."""

import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
FILES = [
    ".gitignore", "README.md", "THIRD_PARTY_NOTICES.md", "docs/architecture.md",
    "Config/Signing.xcconfig", "Config/Signing.local.xcconfig.example",
    "Sign2Speak.xcodeproj/project.pbxproj",
    "Sign2Speak.xcodeproj/xcshareddata/xcschemes/Sign2Speak.xcscheme",
    "Sign2Speak.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
    "Sign2Speak.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "tools/open-xcode.command", "tools/prepare_models.py", "tools/model-assets.json",
    "tools/fetch_landmark_models.py", "tools/classifier_fixture.py",
    "tools/check_checkout.py", "tools/run_app_checks.sh", "tools/export_source.py",
    "tools/generate_app_icon.swift",
    "Packages/TensorFlowLiteSwift/Package.swift", "Packages/TensorFlowLiteSwift/LICENSE",
    "Packages/TensorFlowLiteSwift/NOTICE.md", "Packages/TensorFlowLiteSwift/PROVENANCE.json",
]


def selected_files():
    paths = set(FILES)
    if (ROOT / "LICENSE").is_file():
        paths.add("LICENSE")
    patterns = {
        "Sign2Speak": ["*.swift", "*.storyboard"],
        "Sign2Speak/Models": ["reference_classifier_v1.json"],
        "Sign2Speak/Assets.xcassets": ["**/*.json", "**/*.png"],
        "Sign2Speak/LaunchAssets": ["*.png"],
        "Packages/TensorFlowLiteSwift/Sources": ["**/*.swift"],
        "tests": ["*.swift", "*.py", "fixtures/*.json"],
    }
    for directory, globs in patterns.items():
        for pattern in globs:
            for path in (ROOT / directory).glob(pattern):
                paths.add(path.relative_to(ROOT).as_posix())
    return sorted(paths)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/publication-source")
    parser.add_argument("--list", action="store_true", help="Print selected paths without writing")
    args = parser.parse_args()
    paths = selected_files()
    for name in paths:
        path = ROOT / name
        if not path.is_file() or path.is_symlink():
            parser.error("Missing or symlinked input: " + name)
    if args.list:
        print("\n".join(paths))
        return
    output = args.output.expanduser().resolve()
    if output.exists() or output == ROOT or ROOT in output.parents and ".build" not in output.relative_to(ROOT).parts:
        parser.error("Use a new directory outside the source tree or inside its .build directory")
    output.mkdir(parents=True)
    for name in paths:
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
    print("Exported " + str(len(paths)) + " source files to " + str(output))
    print("No private signing, models, caches, historical notes or Git metadata were copied.")
    print("Next: python3 tools/check_checkout.py --source-only inside the export.")


if __name__ == "__main__":
    main()

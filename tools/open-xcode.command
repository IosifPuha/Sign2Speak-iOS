#!/bin/sh
set -eu

# SwiftPM checks out the complete LiteRT-LM repository, including unrelated
# native LFS prebuilts. Its pinned Swift manifest downloads Apple XCFrameworks
# independently, so those LFS objects need not be fetched for this app.
project_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
lfs_executable="$(command -v git-lfs || true)"
if [ ! -x "$lfs_executable" ]; then
    for lfs_candidate in "${HOME}/.local/bin/git-lfs" /opt/homebrew/bin/git-lfs /usr/local/bin/git-lfs; do
        if [ -x "$lfs_candidate" ]; then
            lfs_executable="$lfs_candidate"
            break
        fi
    done
fi
if [ ! -x "$lfs_executable" ]; then
    echo "Git LFS is required by dependency checkout. Install it (for example: brew install git-lfs), then retry."
    exit 1
fi

for setup_file in Sign2Speak.xcodeproj/project.pbxproj Sign2Speak.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Packages/TensorFlowLiteSwift/Package.swift Config/Signing.xcconfig; do
    if [ ! -f "${project_dir}/${setup_file}" ]; then
        echo "Incomplete checkout: missing ${setup_file}. See README.md."
        exit 1
    fi
done

lfs_bin_dir="$(dirname -- "$lfs_executable")"
xcode_search_path="${lfs_bin_dir}:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [ "${1:-}" = "--check" ]; then
    echo "Project, local package and package lock present."
    echo "Git LFS: ${lfs_executable}"
    echo "Xcode launch environment: Git LFS on PATH, GIT_LFS_SKIP_SMUDGE=1."
    echo "Preflight passed; package resolution and native build still require Xcode."
    exit 0
fi
if [ "$#" -ne 0 ]; then
    echo "Usage: sh tools/open-xcode.command [--check]"
    exit 1
fi

if ! python3 "${project_dir}/tools/prepare_models.py" --verify; then
    echo "Prepare bundled models before opening Xcode. See README.md."
    exit 1
fi

# An already running Xcode keeps its old environment, even when opening a new
# project. Do not quit it automatically: unsaved work may be open.
if /usr/bin/pgrep -x Xcode >/dev/null 2>&1; then
    echo "Quit Xcode with Command-Q, then run this launcher again."
    exit 1
fi
exec /usr/bin/open -a Xcode --env "PATH=${xcode_search_path}" --env GIT_LFS_SKIP_SMUDGE=1 "${project_dir}/Sign2Speak.xcodeproj"

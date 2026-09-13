#!/bin/bash
# Build/render fixture UI from a temporary copy. The production app is never
# launched, and the source checkout's AppDelegate is never modified.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -n "${HOLMES_UI_PREVIEW_WORKSPACE:-}" ]; then
    preview_dir="$HOLMES_UI_PREVIEW_WORKSPACE"
    if [ ! -f "$preview_dir/.holmes-ui-preview" ]; then
        printf 'Refusing to reuse an unmarked preview workspace: %s\n' "$preview_dir" >&2
        exit 2
    fi
else
    preview_dir="$(mktemp -d "${TMPDIR:-/tmp}/holmes-ui-preview.XXXXXX")"
    touch "$preview_dir/.holmes-ui-preview"
fi
preview_output="${1:-$preview_dir/images}"
mkdir -p "$preview_output"
preview_output="$(cd "$preview_output" && pwd)"
preview_bundle="com.zeroprompt.holmes.ui-preview.$(basename "$preview_dir" | tr '[:upper:]' '[:lower:]')"

# Only the Xcode app tree is needed; no repository metadata, user state, build
# products, or credential files are copied.
rsync -a --delete --exclude='.git' --exclude='.build' --exclude='build' --exclude='DerivedData' \
  --exclude='tests' "$repo_root/holmes/" "$preview_dir/project/"
cp "$repo_root/holmes/tests/UIPreviewAppDelegate.swift" "$preview_dir/project/holmes/App/AppDelegate.swift"

# Optional visual fixture: open the Advanced disclosure in the TEMPORARY copy
# only. No production initializer/API is added and no configuration is changed.
if [ "${HOLMES_UI_PREVIEW_EXPAND_ADVANCED:-0}" = "1" ]; then
    python3 - "$preview_dir/project/holmes/Views/Settings/LocalModelSettingsView.swift" <<'PYFIXTURE'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
needle = "@State private var showAdvanced = false"
if source.count(needle) != 1:
    raise SystemExit("Advanced fixture anchor changed; inspect the view before updating this harness")
path.write_text(source.replace(needle, "@State private var showAdvanced = true"))
PYFIXTURE
fi

# Use an independent package cache so a simultaneous production xcodebuild is
# never sharing mutable build/package state with this preview build.
preview_cache="${HOLMES_UI_PREVIEW_PACKAGE_CACHE:-}"
preview_package_args=(-clonedSourcePackagesDirPath "$preview_dir/SourcePackages")
if [ -n "$preview_cache" ] && [ -d "$preview_cache/checkouts" ] && [ ! -d "$preview_dir/SourcePackages" ]; then
    cp -cR "$preview_cache" "$preview_dir/SourcePackages" 2>/dev/null || \
      ditto "$preview_cache" "$preview_dir/SourcePackages"
fi
if [ -d "$preview_dir/SourcePackages/checkouts" ]; then
    preview_package_args=(-clonedSourcePackagesDirPath "$preview_dir/SourcePackages" -disableAutomaticPackageResolution -skipPackageUpdates)
fi

printf 'Preview workspace: %s\n' "$preview_dir"
if ! xcodebuild -project "$preview_dir/project/holmes.xcodeproj" -scheme holmes \
    -configuration Debug -derivedDataPath "$preview_dir/DerivedData" \
    "${preview_package_args[@]}" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    "PRODUCT_BUNDLE_IDENTIFIER=$preview_bundle" build > "$preview_dir/build.log" 2>&1; then
    tail -80 "$preview_dir/build.log"
    exit 1
fi

# No network operation can reach a real service even if a future view adds an
# accidental request in onAppear. The preview delegate never starts engines.
cat > "$preview_dir/offline.sb" <<'PROFILE'
(version 1)
(allow default)
(deny network*)
PROFILE
preview_app="$preview_dir/DerivedData/Build/Products/Debug/holmes.app/Contents/MacOS/holmes"
if ! HOLMES_UI_PREVIEW_OUTPUT="$preview_output" /usr/bin/sandbox-exec -f "$preview_dir/offline.sb" \
    "$preview_app" > "$preview_dir/render.log" 2>&1; then
    cat "$preview_dir/render.log"
    exit 1
fi
cat "$preview_dir/render.log"
printf 'Images: %s\nBuild log: %s\n' "$preview_output" "$preview_dir/build.log"

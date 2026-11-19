#!/usr/bin/env bash
# qa-screens.sh [device names...]
#
# Generates the uitest Xcode project, runs ScreenshotTests on each device,
# exports attachments from .xcresult, and builds contact sheets with scripts/qa-sheets.py:
# phones-portrait.png, phones-landscape.png, pads-portrait.png, pads-landscape.png (a row per device, a column per
# capture: in use, edit mode, and the offline PYXIS in Test Mode, upright and at one height).
#
# Usage:
#   scripts/qa-screens.sh
#   scripts/qa-screens.sh "iPhone 17 Pro" "iPhone 17e"
#
# Output: qa-out/<timestamp>/
#   <device>/portrait-normal.png  landscape-normal.png  portrait-edit.png …
#   phones-portrait.png  phones-landscape.png  pads-portrait.png  pads-landscape.png  (contact sheets)
#
# Requirements:
#   xcodegen, Xcode (DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer),
#   uv (for Pillow-powered contact sheets)

set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/App"
TEMP_DIR="${TMPDIR:-/tmp}/tiles-qa-harness"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$REPO_ROOT/qa-out/$TIMESTAMP"

mkdir -p "$TEMP_DIR" "$OUT_DIR"

# ---------------------------------------------------------------------------
# Device list
# ---------------------------------------------------------------------------

# Default devices (name::os_version pairs; use :: to split later)
DEFAULT_DEVICES=(
    "iPhone 17 Pro::26.5"
    "iPhone 17 Pro Max::26.5"
    "iPhone 17e::26.5"
    "iPhone SE (3rd generation)::17.2"
    "iPad mini (A17 Pro)::26.5"
    "iPad Air 11-inch (M4)::26.5"
    "iPad Pro 13-inch (M5)::26.5"
)

if [[ $# -gt 0 ]]; then
    # Build from arguments: look up OS version from defaults, fall back to 26.5
    USER_DEVICES=()
    for arg in "$@"; do
        found=""
        for d in "${DEFAULT_DEVICES[@]}"; do
            name="${d%%::*}"
            if [[ "$name" == "$arg" ]]; then
                found="$d"
                break
            fi
        done
        if [[ -n "$found" ]]; then
            USER_DEVICES+=("$found")
        else
            USER_DEVICES+=("$arg::26.5")
        fi
    done
    DEVICES=("${USER_DEVICES[@]}")
else
    DEVICES=("${DEFAULT_DEVICES[@]}")
fi

# ---------------------------------------------------------------------------
# Generate Xcode project
# ---------------------------------------------------------------------------

echo "==> Generating Xcode project from uitest.yml …"
cd "$APP_DIR"
xcodegen generate --spec uitest.yml --quiet
echo "    done."

# ---------------------------------------------------------------------------
# Run tests per device
# ---------------------------------------------------------------------------

FAILED_DEVICES=()

for entry in "${DEVICES[@]}"; do
    DEVICE_NAME="${entry%%::*}"
    OS_VERSION="${entry##*::}"
    DEVICE_SLUG="$(echo "$DEVICE_NAME" | tr ' ()' '---' | tr -s '-')"
    RESULT_PATH="$TEMP_DIR/${DEVICE_SLUG}.xcresult"
    ATTACH_DIR="$OUT_DIR/$DEVICE_SLUG"

    echo ""
    echo "==> $DEVICE_NAME (iOS $OS_VERSION)"

    # Remove stale result bundle
    rm -rf "$RESULT_PATH"

    DESTINATION="platform=iOS Simulator,name=${DEVICE_NAME},OS=${OS_VERSION}"

    XC_LOG="$TEMP_DIR/${DEVICE_SLUG}-xcodebuild.log"
    xcodebuild test \
        -project "$APP_DIR/CameraControl.xcodeproj" \
        -scheme TilesUITests \
        -only-testing "TilesUITests/ScreenshotTests" \
        -destination "$DESTINATION" \
        -resultBundlePath "$RESULT_PATH" \
        -derivedDataPath "$TEMP_DIR/DerivedData-${DEVICE_SLUG}" \
        CODE_SIGNING_ALLOWED=NO \
        > "$XC_LOG" 2>&1
    XC_RC=$?
    # Show the key result line from the log
    grep -E "Executed|TEST SUCCEEDED|TEST FAILED" "$XC_LOG" | tail -3 || true
    if [[ $XC_RC -eq 0 ]]; then
        echo "    Tests passed."
    else
        echo "    WARNING: xcodebuild exited $XC_RC for $DEVICE_NAME — attachments may still be present."
        FAILED_DEVICES+=("$DEVICE_NAME")
    fi

    # Export attachments even if tests failed (screenshots are captured before assertions)
    mkdir -p "$ATTACH_DIR"
    if [[ -d "$RESULT_PATH" ]]; then
        xcrun xcresulttool export attachments \
            --path "$RESULT_PATH" \
            --output-path "$ATTACH_DIR" \
            2>&1 || echo "    WARNING: xcresulttool export returned non-zero for $DEVICE_NAME"

        # Rename from manifest-based names to <name>.png
        if [[ -f "$ATTACH_DIR/manifest.json" ]]; then
            python3 - "$ATTACH_DIR" <<'PYEOF'
import json, os, sys, shutil, re

attach_dir = sys.argv[1]
with open(os.path.join(attach_dir, "manifest.json")) as f:
    manifest = json.load(f)

# Manifest is a list of test-level objects; attachments are nested inside each.
for test_entry in manifest:
    for item in test_entry.get("attachments", []):
        src_name = item.get("exportedFileName", "")
        # suggestedHumanReadableName looks like "portrait-normal_0_UUID.png"
        raw_name = item.get("suggestedHumanReadableName", "")
        if not src_name or not raw_name:
            continue
        # Strip the trailing _0_UUID suffix to get a clean name
        clean = re.sub(r'_\d+_[0-9A-Fa-f-]+\.png$', '', raw_name)
        if not clean:
            clean = raw_name
        dst_base = clean if clean.endswith(".png") else clean + ".png"
        src = os.path.join(attach_dir, src_name)
        dst = os.path.join(attach_dir, dst_base)
        if os.path.exists(src) and not os.path.exists(dst):
            shutil.copy2(src, dst)
            print(f"  renamed {src_name} -> {dst_base}")
PYEOF
        fi
    else
        echo "    WARNING: no .xcresult bundle found at $RESULT_PATH"
        FAILED_DEVICES+=("$DEVICE_NAME (no bundle)")
    fi
done

# ---------------------------------------------------------------------------
# Build contact sheets
# ---------------------------------------------------------------------------

echo ""
echo "==> Building contact sheets …"

uv run --with pillow python3 "$REPO_ROOT/scripts/qa-sheets.py" "$OUT_DIR"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "==> Output: $OUT_DIR"
echo ""
if [[ ${#FAILED_DEVICES[@]} -gt 0 ]]; then
    echo "Devices with issues:"
    for d in "${FAILED_DEVICES[@]}"; do
        echo "  - $d"
    done
else
    echo "All devices passed."
fi
echo ""
echo "Contact sheets:"
ls -lh "$OUT_DIR"/*.png 2>/dev/null || echo "  (not generated)"

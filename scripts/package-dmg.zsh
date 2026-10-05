#!/usr/bin/env zsh
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${REMOTE_DICTATE_PACKAGE_MODE:-preview}"
version="$(tr -d '[:space:]' < "$repo_root/VERSION")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'error: invalid version'; exit 1; }
case "$mode" in
  preview)
    export REMOTE_DICTATE_CODESIGN_IDENTITY=- REMOTE_DICTATE_DISTRIBUTION=0
    suffix='-unnotarized'
    ;;
  notarized)
    export REMOTE_DICTATE_DISTRIBUTION=1
    : "${REMOTE_DICTATE_NOTARY_PROFILE:?Set a notarytool keychain profile for notarized packaging}"
    suffix=''
    ;;
  *) print -u2 'error: package mode must be preview or notarized'; exit 1 ;;
esac
export REMOTE_DICTATE_CONFIGURATION=release REMOTE_DICTATE_ARCHS=arm64
package_root="$repo_root/.build/package"
staging="$(mktemp -d "${TMPDIR:-/tmp}/rdh-package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$package_root" "$staging/image"
"$repo_root/scripts/build-menubar-app.zsh" "$staging/apps"
app="$staging/apps/Remote Dictate Helper.app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/lipo "$app/Contents/MacOS/Remote Dictate Helper" -verify_arch arm64
keychain_args=()
[[ -z "${REMOTE_DICTATE_KEYCHAIN:-}" ]] || keychain_args=(--keychain "$REMOTE_DICTATE_KEYCHAIN")
notarize() {
  /usr/bin/xcrun notarytool submit "$1" --keychain-profile "$REMOTE_DICTATE_NOTARY_PROFILE" "${keychain_args[@]}" --wait --output-format json > "$staging/notary-result.json"
  python3 - "$staging/notary-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted; refusing to release.')
PY
}
if [[ "$mode" == notarized ]]; then
  # Staple the app too, so the installed copy carries its own offline ticket.
  /usr/bin/ditto -c -k --keepParent "$app" "$staging/app.zip"
  notarize "$staging/app.zip"
  /usr/bin/xcrun stapler staple "$app"
  /usr/bin/xcrun stapler validate "$app"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
fi
# No machine-specific files, logs, settings or local signing keys enter the image.
/usr/bin/ditto "$app" "$staging/image/Remote Dictate Helper.app"
ln -s /Applications "$staging/image/Applications"
cp "$repo_root/LICENSE" "$staging/image/License.txt"
cat > "$staging/image/Read Me.txt" <<'EOF'
Remote Dictate Helper

1. Drag Remote Dictate Helper.app to Applications.
2. Eject this disk image and open the app from Applications.
3. In Settings, grant Accessibility and choose dictation apps, then Save.

Runs on your LOCAL Mac. Requires macOS 26 or later and Apple Screen Sharing.
Your dictation app supplies the microphone and transcript. No remote installation.

Updates: quit the existing helper normally before replacing it in Applications.
Never force quit while it is restoring your clipboard.

Source, documentation and releases:
https://github.com/elyrix-systems/remote-dictate-helper
EOF
if [[ "$mode" == preview ]]; then
  cat >> "$staging/image/Read Me.txt" <<'EOF'

UNNOTARIZED DOWNLOAD — not signed with an Apple Developer ID.
macOS may block its first launch. After verifying the download and deciding you
trust it, use System Settings > Privacy & Security > Open Anyway, if available.
Managed Macs may prohibit this. Do not disable Gatekeeper or install certificates.
Updates can require granting Accessibility again. For ordinary users, prefer a
release explicitly marked Developer ID signed and Apple notarized.
EOF
fi
dmg="$package_root/Remote-Dictate-Helper-$version-arm64$suffix.dmg"
[[ ! -e "$dmg" ]] || { print -u2 "error: output already exists: $dmg (move it aside before rebuilding)"; exit 1; }
/usr/bin/hdiutil create -quiet -volname 'Remote Dictate Helper' -srcfolder "$staging/image" -format UDZO "$dmg"
if [[ "$mode" == notarized ]]; then
  /usr/bin/codesign --sign "$REMOTE_DICTATE_CODESIGN_IDENTITY" "${keychain_args[@]}" --timestamp "$dmg"
  notarize "$dmg"
  /usr/bin/xcrun stapler staple "$dmg"
  /usr/bin/xcrun stapler validate "$dmg"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi
/usr/bin/hdiutil verify -quiet "$dmg"
(cd "$package_root" && /usr/bin/shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256")
print "Packaged: $dmg"

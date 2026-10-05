#!/usr/bin/env zsh
# Only ephemeral GitHub-hosted runners. Never import release keys on a user's Mac.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && -n "${RUNNER_TEMP:-}" ]] || { print -u2 'error: GitHub Actions runner required'; exit 1; }
: "${DEVELOPER_ID_P12_BASE64:?Missing certificate}"
: "${DEVELOPER_ID_P12_PASSWORD:?Missing certificate password}"
: "${DEVELOPER_ID_IDENTITY:?Missing Developer ID identity}"
: "${APPLE_ID:?Missing Apple ID}"
: "${APPLE_APP_PASSWORD:?Missing notary credential}"
: "${APPLE_TEAM_ID:?Missing team ID}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
private_dir="$(mktemp -d "$RUNNER_TEMP/rdh-signing.XXXXXX")"
chmod 700 "$private_dir"
keychain="$private_dir/release.keychain-db"
cleanup() {
  /usr/bin/security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$private_dir"
}
trap cleanup EXIT
keychain_password="$(/usr/bin/uuidgen)"
print -rn -- "$DEVELOPER_ID_P12_BASE64" | /usr/bin/base64 --decode > "$private_dir/signing.p12"
/usr/bin/security create-keychain -p "$keychain_password" "$keychain"
/usr/bin/security set-keychain-settings -lut 1800 "$keychain"
/usr/bin/security unlock-keychain -p "$keychain_password" "$keychain"
/usr/bin/security import "$private_dir/signing.p12" -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
/usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
/usr/bin/xcrun notarytool store-credentials rdh-release --keychain "$keychain" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" >/dev/null
export REMOTE_DICTATE_CODESIGN_IDENTITY="$DEVELOPER_ID_IDENTITY"
export REMOTE_DICTATE_KEYCHAIN="$keychain" REMOTE_DICTATE_NOTARY_PROFILE=rdh-release REMOTE_DICTATE_PACKAGE_MODE=notarized
"$repo_root/scripts/package-dmg.zsh"

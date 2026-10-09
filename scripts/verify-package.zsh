#!/usr/bin/env zsh
# Read-only verification. Never launch the mounted app or request permissions.
set -euo pipefail
dmg="${1:?usage: verify-package.zsh DMG}"
mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/rdh-verify.XXXXXX")"
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then /usr/bin/hdiutil detach -quiet "$mount_dir" || return; fi
  rmdir "$mount_dir"
}
trap cleanup EXIT
/usr/bin/hdiutil verify -quiet "$dmg"
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_dir" "$dmg"
mounted=1
app="$mount_dir/Remote Dictate Helper.app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/lipo "$app/Contents/MacOS/Remote Dictate Helper" -verify_arch arm64
[[ "$(/usr/bin/lipo "$app/Contents/MacOS/Remote Dictate Helper" -archs)" == arm64 ]]
[[ "$(readlink "$mount_dir/Applications")" == /Applications ]]
for required in 'License.txt' 'Read Me.txt'; do [[ -s "$mount_dir/$required" ]]; done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == systems.elyrix.RemoteDictateHelper ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")" == 26.0 ]]
# The executable must enforce the same floor as Finder's app metadata.
[[ "$(/usr/bin/xcrun vtool -show-build "$app/Contents/MacOS/Remote Dictate Helper" | /usr/bin/awk '$1 == "minos" {print $2}')" == 26.0 ]]
python3 - "$app/Contents/MacOS/Remote Dictate Helper" "$mount_dir" <<'PY'
from pathlib import Path
import plistlib, re, sys
binary = Path(sys.argv[1]).read_bytes()
metadata = plistlib.loads((Path(sys.argv[1]).parent.parent / "Info.plist").read_bytes())
if any(metadata.get(key) for key in ("RDDiagnosticLogging", "RDDiagnosticTextLogging")):
    raise SystemExit("Download packages must not enable private diagnostic logging.")
if re.search(rb'/(?:Users|home)/[A-Za-z0-9_.-]+', binary):
    raise SystemExit('Executable contains a machine-specific build path; refusing this package.')
allowed = {'Remote Dictate Helper.app', 'Applications', 'License.txt',
           'Read Me.txt', '.fseventsd', '.Trashes'}
if {item.name for item in Path(sys.argv[2]).iterdir()} - allowed:
    raise SystemExit('Unexpected disk image contents; review the package before release.')
PY
print 'DMG verified: Apple-silicon app, valid signature, no home paths, reviewed contents and installation files.'

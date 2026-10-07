#!/usr/bin/env zsh
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="$repo_root/.module-cache"
swift build --product remote-dictate-helper
test_binary_dir="$(swift build --show-bin-path)"
test_module_dir="$test_binary_dir"
core_objects=()
if [[ -f "$test_binary_dir/RemoteDictateCore.o" ]]; then
  core_objects=("$test_binary_dir/RemoteDictateCore.o")
else
  core_objects=("$test_binary_dir"/RemoteDictateCore.build/*.o(N))
  test_module_dir="$test_binary_dir/Modules"
fi
if (( ${#core_objects} == 0 )); then
  print -u2 'Core build output not found'; exit 1
fi
runtime="$repo_root/Sources/RemoteDictateHelper"
swiftc -swift-version 6 -parse-as-library -I "$test_module_dir" \
  Tests/RemoteDictateTests/*.swift \
  "$runtime/PasteEventFilter.swift" "$runtime/DictationPasteMonitor.swift" "$runtime/ClipboardBaselineHistory.swift" \
  "$runtime/CapturedClipboard.swift" "$runtime/LocalClipboardRestoration.swift" \
  "$runtime/DeferredClipboardCompletion.swift" "$runtime/AccessibilityPermission.swift" \
  "$runtime/OperationalLog.swift" "$runtime/LaunchAtLogin.swift" "$runtime/DictationSourceSettings.swift" \
  "$runtime/DiagnosticLog.swift" \
  "$runtime/ExplicitPasteShortcut.swift" \
  "$runtime/WindowsAppPasteShortcut.swift" "$runtime/WindowsAppPasteMonitor.swift" \
  "$runtime/GuardedPaste.swift" "$runtime/ScreenSharingClipboardMenu.swift" \
  "${core_objects[@]}" -o "$repo_root/.build/remote-dictate-tests"
"$repo_root/.build/remote-dictate-tests"

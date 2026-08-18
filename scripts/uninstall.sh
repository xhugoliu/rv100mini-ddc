#!/bin/zsh
set -euo pipefail

binary_path="${HOME}/.local/bin/ddc-input-hotkeys"
plist_path="${HOME}/Library/LaunchAgents/io.local.ddc-input-hotkeys.plist"
launch_domain="gui/$(id -u)"

if [[ -f "${plist_path}" ]]; then
  launchctl bootout "${launch_domain}" "${plist_path}" 2>/dev/null || true
  rm "${plist_path}"
fi

if [[ -f "${binary_path}" ]]; then
  rm "${binary_path}"
fi

echo "Removed the daemon and binary."
echo "Configuration was kept under ~/Library/Application Support/DDCInputHotkeys."

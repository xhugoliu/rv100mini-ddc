#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
binary_name="ddc-input-hotkeys"
install_dir="${HOME}/.local/bin"
config_dir="${HOME}/Library/Application Support/DDCInputHotkeys"
launch_agents_dir="${HOME}/Library/LaunchAgents"
binary_path="${install_dir}/${binary_name}"
config_path="${config_dir}/config.json"
plist_path="${launch_agents_dir}/io.local.ddc-input-hotkeys.plist"
log_path="${config_dir}/ddc-input-hotkeys.log"
launch_domain="gui/$(id -u)"

cd "${project_dir}"
swift build -c release

mkdir -p "${install_dir}" "${config_dir}" "${launch_agents_dir}"
install -m 755 ".build/release/${binary_name}" "${binary_path}"
if [[ ! -f "${config_path}" ]]; then
  install -m 644 "config.example.json" "${config_path}"
fi

if [[ -f "${plist_path}" ]]; then
  launchctl bootout "${launch_domain}" "${plist_path}" 2>/dev/null || true
fi

plutil -create xml1 "${plist_path}"
plutil -insert Label -string "io.local.ddc-input-hotkeys" "${plist_path}"
plutil -insert ProgramArguments -json "[\"${binary_path}\",\"daemon\",\"--config\",\"${config_path}\"]" "${plist_path}"
plutil -insert RunAtLoad -bool true "${plist_path}"
plutil -insert KeepAlive -bool true "${plist_path}"
plutil -insert ProcessType -string Interactive "${plist_path}"
plutil -insert StandardOutPath -string "${log_path}" "${plist_path}"
plutil -insert StandardErrorPath -string "${log_path}" "${plist_path}"

launchctl bootstrap "${launch_domain}" "${plist_path}"

echo "Installed ${binary_path}"
echo "Config:    ${config_path}"
echo "Log:       ${log_path}"
echo "Hotkeys are active and will start automatically at login."

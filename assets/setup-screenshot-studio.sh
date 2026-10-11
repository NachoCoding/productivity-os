#!/bin/bash
# install | update: stage → verify → quit if idle → unload → swap → plist → register → load. Never swaps (or
# unloads, which would SIGTERM unsaved captures) while the old copy runs. Exit 0 = done, 75 = busy (Screenshot
# Studio is in use or too old to ask, or another setup runs; nothing changed).
set -euo pipefail
studio_action="${1:-install}"
studio_label=com.productivity-os.screenshot-studio
studio_source="$(cd "$(dirname "$0")" && pwd)/Screenshot Studio.app"
studio_target="$HOME/Applications/Screenshot Studio.app"
studio_plist="$HOME/Library/LaunchAgents/$studio_label.plist"
studio_lock="$HOME/Applications/.screenshot-studio.setup.lock"
studio_domain="gui/$(id -u)"
# Tool overrides exist for tests with a temporary HOME.
launchctl="${POS_LAUNCHCTL:-/bin/launchctl}" open="${POS_OPEN:-/usr/bin/open}"
pgrep="${POS_PGREP:-/usr/bin/pgrep}" ditto="${POS_DITTO:-/usr/bin/ditto}" codesign="${POS_CODESIGN:-/usr/bin/codesign}"
plutil="${POS_PLUTIL:-/usr/bin/plutil}"
lsregister="${POS_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
# quit-if-idle exits at once when idle and never when busy, so a long wait only delays Raycast.
quit_wait="${POS_QUIT_WAIT:-2}"
[[ "$quit_wait" =~ ^[0-9]+$ ]] || quit_wait=2
[[ "$studio_action" =~ ^(install|update|uninstall)$ ]] || { echo 'Usage: setup-screenshot-studio.sh install|update|uninstall' >&2; exit 64; }
for studio_path in "$HOME/Applications" "$studio_target" "$HOME/Library/LaunchAgents" "$studio_plist"; do
  [[ ! -L "$studio_path" ]] || { echo 'Refusing a symbolic-link installation target.' >&2; exit 1; }
done
[[ "$studio_action" == uninstall || -x "$studio_source/Contents/MacOS/ScreenshotStudio" ]] || { echo 'Build Screenshot Studio first.' >&2; exit 1; }
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"

studio_stage='' studio_locked=''
studio_cleanup() {
  # An interrupted swap puts the previous copy back.
  if [[ -n "$studio_stage" && -e "$studio_stage/previous.app" && ! -e "$studio_target" ]]; then
    mv "$studio_stage/previous.app" "$studio_target" || true
  fi
  [[ -z "$studio_stage" ]] || rm -rf "$studio_stage"
  [[ -z "$studio_locked" ]] || rm -rf "$studio_lock"
}
studio_signals() { trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; }
trap studio_cleanup EXIT
studio_signals
# One setup at a time. A lock whose holder is gone (or older than any run) is stale.
studio_take_lock() {
  local holder modified
  for _ in 1 2 3; do
    if mkdir "$studio_lock" 2>/dev/null; then
      studio_locked=1
      echo "$$" >"$studio_lock/pid"
      return 0
    fi
    modified="$(stat -f %m "$studio_lock" 2>/dev/null)" || continue
    holder="$(cat "$studio_lock/pid" 2>/dev/null || true)"
    if (($(date +%s) - modified < 600)); then
      if [[ "$holder" =~ ^[0-9]+$ ]]; then
        if kill -0 "$holder" 2>/dev/null; then return 1; fi
      elif (($(date +%s) - modified < 10)); then
        return 1 # The holder is still writing its pid.
      fi
    fi
    if mv "$studio_lock" "$studio_lock.stale.$$" 2>/dev/null; then rm -rf "$studio_lock.stale.$$"; fi
  done
  return 1
}
studio_running() { "$pgrep" -f "^$studio_target/Contents/MacOS/ScreenshotStudio" >/dev/null; }
# Only builds that advertise the launcher protocol understand quit-if-idle; older ones count as busy.
studio_quittable() {
  [[ "$("$plutil" -extract POSLauncherProtocol raw -o - "$studio_target/Contents/Info.plist" 2>/dev/null)" =~ ^[1-9][0-9]*$ ]]
}
studio_busy() {
  if studio_quittable; then
    echo "Screenshot Studio is in use (open windows, pinned images, or a capture or recording), so nothing was changed. Close them to finish $1." >&2
  else
    echo "Screenshot Studio is running a build that cannot be asked to quit, so nothing was changed. Open its settings and press ⌘Q to finish $1." >&2
  fi
  exit 75
}
# Asks a running copy to quit if it is idle and waits for it; fails if it is still running.
studio_quit() {
  studio_running || return 0
  studio_quittable || return 1
  "$open" -g -a "$studio_target" 'pos-screenshot://quit-if-idle' >/dev/null 2>&1 || true
  for ((studio_poll = 0; studio_poll < quit_wait * 5; studio_poll++)); do
    studio_running || return 0
    sleep 0.2
  done
  ! studio_running
}
studio_requirement() { "$codesign" -d -r- "$1" 2>/dev/null | sed -n 's/^# *//; s/^designated => //p' || true; }
studio_write_plist() {
  local plist="$studio_stage/login.plist"
  "$plutil" -create xml1 "$plist"
  "$plutil" -insert Label -string "$studio_label" "$plist"
  "$plutil" -insert ProgramArguments -json '[]' "$plist"
  "$plutil" -insert ProgramArguments.0 -string "$studio_target/Contents/MacOS/ScreenshotStudio" "$plist"
  "$plutil" -insert ProgramArguments.1 -string --background "$plist"
  "$plutil" -insert RunAtLoad -bool YES "$plist"
  "$plutil" -insert KeepAlive -json '{"SuccessfulExit":false}' "$plist"
  "$plutil" -insert ProcessType -string Interactive "$plist"
  "$plutil" -insert ThrottleInterval -integer 30 "$plist"
  "$plutil" -insert LimitLoadToSessionType -string Aqua "$plist"
  mv "$plist" "$studio_plist"
}

studio_take_lock || { echo 'Another Screenshot Studio setup is running; try again shortly.' >&2; exit 75; }
if [[ "$studio_action" == uninstall ]]; then
  studio_quit || studio_busy 'removing it'
  "$launchctl" bootout "$studio_domain/$studio_label" 2>/dev/null || true
  rm -f "$studio_plist"
  rm -rf "$studio_target"
  echo 'Screenshot Studio removed.'
  exit 0
fi
# A running build that cannot be asked to quit makes staging pointless.
if studio_running && ! studio_quittable; then studio_busy updating; fi
studio_stage="$(mktemp -d "$HOME/Applications/.screenshot-studio.XXXXXX")"
"$ditto" "$studio_source" "$studio_stage/Screenshot Studio.app"
"$codesign" --verify --deep --strict "$studio_stage/Screenshot Studio.app" ||
  { echo 'The bundled Screenshot Studio failed signature verification; rebuild it.' >&2; exit 1; }
if [[ -e "$studio_target" && "$(studio_requirement "$studio_target")" != "$(studio_requirement "$studio_stage/Screenshot Studio.app")" ]]; then
  echo 'Warning: this Screenshot Studio build is signed differently, so macOS will ask for Screen Recording (and Accessibility, for scrolling captures) again.' >&2
fi
studio_quit || studio_busy updating
# Unload, swap and plist must not stop halfway.
trap '' HUP INT TERM
"$launchctl" bootout "$studio_domain/$studio_label" 2>/dev/null || true
if [[ -e "$studio_target" ]]; then mv "$studio_target" "$studio_stage/previous.app"; fi
if ! mv "$studio_stage/Screenshot Studio.app" "$studio_target"; then
  [[ ! -e "$studio_stage/previous.app" ]] || mv "$studio_stage/previous.app" "$studio_target"
  exit 1
fi
# Resident helper owns the global ⌘⇧2 area-capture shortcut.
studio_write_plist
studio_signals
"$lsregister" -f "$studio_target" || echo 'Warning: Launch Services did not register Screenshot Studio.' >&2
"$launchctl" bootstrap "$studio_domain" "$studio_plist" 2>/dev/null ||
  "$launchctl" kickstart "$studio_domain/$studio_label" 2>/dev/null ||
  echo 'Warning: launchd did not start Screenshot Studio (Login Items may be off); ⌘⇧2 works once it is opened.' >&2
if [[ "$studio_action" == update ]]; then echo "Updated $studio_target (⌘⇧2 captures an area)"; else echo "Installed $studio_target (⌘⇧2 captures an area)"; fi

#!/bin/bash
set -euo pipefail
# Run via sudo; the original login user receives access to the fixed helper.
[ "$EUID" -eq 0 ] || { echo 'Run this installer with sudo.' >&2; exit 1; }
user=${SUDO_USER:?Run with sudo from your own account}
[ "$user" != root ] || { echo 'Run this installer with sudo from your own (non-root) account.' >&2; exit 1; }
[[ "$user" =~ ^[a-zA-Z0-9_][a-zA-Z0-9._-]*$ ]] || { echo "Unsupported account name for a sudoers rule: $user" >&2; exit 1; }
source_dir=$(cd "$(dirname "$0")" && pwd)
helper_dir=/Library/PrivilegedHelperTools/productivity-os
plist=/Library/LaunchDaemons/com.productivity-os.expire.plist
# Reject unsafe existing installation directories rather than following links.
[ ! -L "$helper_dir" ] || { echo "$helper_dir is a symlink; remove it and rerun." >&2; exit 1; }
[ -f "$source_dir/blocker.sh" ] || { echo "Missing $source_dir/blocker.sh" >&2; exit 1; }
[ -x "$source_dir/focus-probe" ] || { echo 'Build the bundled focus probe before running Setup.' >&2; exit 1; }
for managed_file in "$helper_dir/blocker.sh" "$helper_dir/focus-probe" "$helper_dir/owner-uid" "$helper_dir/state.json"; do
  [ ! -L "$managed_file" ] || { echo "Refusing symbolic-link target: $managed_file" >&2; exit 1; }
done
owner_uid=$(/usr/bin/id -u "$user")
if [ -f "$helper_dir/owner-uid" ] && [ "$(cat "$helper_dir/owner-uid")" != "$owner_uid" ]; then
  echo 'The installed focus helper belongs to another account. Use the original account to update it.' >&2
  exit 1
fi
/usr/bin/install -d -o root -g wheel -m 755 "$helper_dir"
# Files are staged beside their targets and renamed into place (install -S also flushes them): the expire
# daemon and concurrent sudo calls run either the old copy or the new one, never a partial file.
# Without a working probe the helper pauses every Pomodoro round, so the staged root-owned probe must
# read this login session for the owner before it replaces the installed one.
staged_probe="$helper_dir/.focus-probe.new"
/usr/bin/install -S -o root -g wheel -m 755 "$source_dir/focus-probe" "$staged_probe"
probe_state=$("$staged_probe" "$owner_uid" 2>&1) || probe_state="it failed to run (${probe_state:-no output})"
if [[ "$probe_state" != *'"available":true'* ]]; then
  /bin/rm -f "$staged_probe"
  echo "The focus probe cannot read the login session state: $probe_state. Run Setup from your logged-in desktop session; if this persists, rebuild the probe with npm run build:focus-probe." >&2
  exit 1
fi
[[ "$probe_state" == *'"idleMs":'* ]] || echo 'Warning: the focus probe did not report idle time, so a stalled Pomodoro round cannot be ended early. Rebuild it with npm run build:focus-probe and rerun Setup.' >&2
/bin/mv -f "$staged_probe" "$helper_dir/focus-probe"
printf '%s\n' "$owner_uid" > "$helper_dir/owner-uid"
/usr/sbin/chown root:wheel "$helper_dir/owner-uid"
/bin/chmod 644 "$helper_dir/owner-uid"
/usr/bin/install -S -o root -g wheel -m 755 "$source_dir/blocker.sh" "$helper_dir/blocker.sh"
tmp=$(/usr/bin/mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$helper_dir/blocker.sh" > "$tmp"
/usr/sbin/visudo -cf "$tmp"
/usr/bin/install -d -o root -g wheel -m 755 /etc/sudoers.d
/usr/bin/install -o root -g wheel -m 440 "$tmp" /etc/sudoers.d/productivity-os
cat > "$tmp" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.productivity-os.expire</string>
<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/productivity-os/blocker.sh</string><string>expire</string></array>
<key>StartInterval</key><integer>30</integer>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$tmp"
/bin/launchctl bootout system/com.productivity-os.expire 2>/dev/null || true
# bootout returns before launchd has finished removing the job; bootstrapping too early fails.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  /bin/launchctl print system/com.productivity-os.expire >/dev/null 2>&1 || break
  /bin/sleep 0.5
done
/usr/bin/install -o root -g wheel -m 644 "$tmp" "$plist"
/bin/launchctl bootstrap system "$plist" || { /bin/sleep 2; /bin/launchctl bootstrap system "$plist"; }
# Upgrade from the Site Blocker name: adopt its hosts section, then remove its installation.
old_dir=/Library/PrivilegedHelperTools/site-blocker
"$helper_dir/blocker.sh" expire || { echo 'Could not migrate the existing /etc/hosts section; repair it and rerun. The Site Blocker installation was left in place.' >&2; exit 1; }
/bin/launchctl bootout system/com.site-blocker.expire 2>/dev/null || true
/bin/rm -f /Library/LaunchDaemons/com.site-blocker.expire.plist /etc/sudoers.d/site-blocker
if [ -d "$old_dir" ] && [ ! -L "$old_dir" ]; then
  /bin/rm -f "$old_dir/blocker.sh"
  /bin/rmdir "$old_dir" 2>/dev/null || true
fi
echo 'Productivity OS installed. Reopen the Raycast command.'

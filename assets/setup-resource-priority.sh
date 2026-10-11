#!/bin/bash
set -euo pipefail
[[ "$EUID" == 0 ]] || { echo 'Run this installer with sudo from your own account.' >&2; exit 1; }
user="${SUDO_USER:?Run with sudo from your own account}"
uid="${SUDO_UID:?Missing original user ID}"
[[ "$user" != root && "$user" =~ ^[a-zA-Z0-9_][a-zA-Z0-9._-]*$ && "$uid" =~ ^[0-9]+$ && "$uid" != 0 ]] || exit 1
assets_dir="$(cd "$(dirname "$0")" && pwd)"
directory=/Library/PrivilegedHelperTools/productivity-os
helper="$directory/resource-priority"
label="com.productivity-os.resource-priority.$uid"
plist="/Library/LaunchDaemons/$label.plist"
rule="/etc/sudoers.d/productivity-os-resource-priority-$uid"
[[ ! -L "$directory" && ! -L /var/db/productivity-os-resource-priority ]] || { echo 'Unsafe installation directory' >&2; exit 1; }

if [[ "${1:-install}" == uninstall ]]; then
  "$helper" disable
  remaining="$("$helper" status | /usr/bin/plutil -extract processCount raw -o - -)"
  [[ "$remaining" == 0 ]] || { echo 'Some priorities could not be restored; retry before removal.' >&2; exit 1; }
  /bin/launchctl bootout "system/$label" 2>/dev/null || true
  rm -f "$plist" "$rule"
  echo 'CPU priority disabled and this account’s service removed.'
  exit 0
fi
[[ "${1:-install}" == install ]] || exit 64
[[ -x "$assets_dir/resource-priority" ]] || { echo 'Run npm run build:resource-priority first.' >&2; exit 1; }
/usr/bin/install -d -o root -g wheel -m 755 "$directory"
temporary="$(mktemp)"
trap 'rm -f "$temporary"' EXIT
printf '%s ALL=(root) NOPASSWD: %s enable, %s disable, %s status\n' "$user" "$helper" "$helper" "$helper" > "$temporary"
/usr/sbin/visudo -cf "$temporary"
/bin/launchctl bootout "system/$label" 2>/dev/null || true
/usr/bin/install -o root -g wheel -m 755 "$assets_dir/resource-priority" "$helper.new"
mv -f "$helper.new" "$helper"
/usr/bin/install -d -o root -g wheel -m 755 /etc/sudoers.d
/usr/bin/install -o root -g wheel -m 440 "$temporary" "$rule"
cat > "$temporary" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$helper</string><string>tick</string><string>$uid</string></array>
<key>StartInterval</key><integer>5</integer>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$temporary"
/usr/bin/install -o root -g wheel -m 644 "$temporary" "$plist"
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  /bin/launchctl print "system/$label" >/dev/null 2>&1 || break
  sleep 0.5
done
/bin/launchctl bootstrap system "$plist"
"$helper" enable
echo 'CPU scheduling priority enabled for Warp, Codex, Claude, and their child processes. RAM controls remain separate.'

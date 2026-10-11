#!/bin/bash
set -euo pipefail
umask 077

action="${1:-install}"
assets_dir="$(cd "$(dirname "$0")" && pwd)"
support="$HOME/Library/Application Support/Productivity OS/Resource Guard"
binary="$support/resource-guard"
label="com.productivity-os.resource-guard"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
launcher="$HOME/.local/bin/resource-guard"
status_file=''
maintenance_acquired=false
cleanup() {
  result=$?
  [[ -z "$status_file" ]] || rm -f "$status_file"
  if [[ "$result" != 0 && "$maintenance_acquired" == true && -x "$binary" ]]; then "$binary" resume >/dev/null 2>&1 || true; fi
  exit "$result"
}
trap cleanup EXIT

if [[ "$action" != install && "$action" != uninstall ]]; then
  echo 'Usage: setup-resource-guard.sh install|uninstall' >&2
  exit 64
fi

# Never follow unexpected install-target symlinks, including stale staging files.
for target in "$support" "$binary" "$binary.new" "$plist" "$plist.new"; do
  [[ ! -L "$target" ]] || { echo "Unsafe installation symlink: $target" >&2; exit 1; }
done

# Never unload or replace an installed coordinator while work is queued or running.
if [[ -x "$binary" ]]; then
  status_file="$(mktemp)"
  if "$binary" status --json > "$status_file" 2>/dev/null; then
    /usr/bin/plutil -extract jobs json -o - "$status_file" | /usr/bin/grep -Eq '^\[[[:space:]]*\]$' || {
      echo 'Resource Guard has queued or running jobs. Let them finish before updating or removing it.' >&2
      exit 1
    }
    "$binary" maintenance
    maintenance_acquired=true
  elif [[ -f "$support/registry.json" ]]; then
    /usr/bin/plutil -extract jobs json -o - "$support/registry.json" | /usr/bin/grep -Eq '^\[[[:space:]]*\]$' || {
      # Restart the existing helper so it can reconcile survivors; do not delete its state.
      /bin/launchctl kickstart "$domain/$label" 2>/dev/null || true
      echo 'Guard state contains jobs and monitoring is unavailable. Restore the coordinator and retry after reconciliation.' >&2
      exit 1
    }
  fi
fi

if [[ -e "$launcher" && ! -L "$launcher" ]]; then
  echo "Refusing to replace an unrelated launcher: $launcher" >&2
  exit 1
fi
if [[ -L "$launcher" && "$(readlink "$launcher")" != "$binary" ]]; then
  echo "Refusing to replace an unrelated symlink: $launcher" >&2
  exit 1
fi

update_instructions() {
  target="$1" mode="$2"
  [[ ! -L "$target" ]] || { echo "Instruction file is a symlink: $target" >&2; exit 1; }
  mkdir -p "$(dirname "$target")"
  if [[ -f "$target" ]]; then
    backup="$(mktemp "$target.resource-guard-backup-XXXXXX")"
    cp -p "$target" "$backup"
  fi
  /usr/bin/perl - "$target" "$assets_dir/resource-guard-instructions.md" "$mode" <<'PERL'
use strict;
use warnings;
use File::Temp qw(tempfile);
my ($target, $instructions, $mode) = @ARGV;
my $old = '';
if (-e $target) { open my $f, '<', $target or die $!; local $/; $old = <$f>; close $f; }
my $start = '<!-- productivity-os-resource-guard:start -->';
my $end = '<!-- productivity-os-resource-guard:end -->';
my $starts = () = $old =~ /\Q$start\E/g;
my $ends = () = $old =~ /\Q$end\E/g;
die "Malformed Resource Guard instruction markers\n" if $starts != $ends || $starts > 1;
my $block = '';
if ($mode eq 'install') {
  open my $f, '<', $instructions or die $!; local $/; my $body = <$f>; close $f;
  $block = "$start\n$body$end";
}
if ($starts) { $old =~ s/\Q$start\E.*?\Q$end\E/$block/s or die "Reversed instruction markers\n"; }
elsif ($mode eq 'install') { $old .= "\n\n$block\n"; }
my ($out, $temporary) = tempfile("$target.resource-guard-new-XXXXXX", UNLINK => 0);
chmod((stat($target))[2] & 0777, $temporary) if -f $target;
print $out $old; close $out or die $!;
rename $temporary, $target or die $!;
PERL
}

if [[ "$action" == uninstall ]]; then
  /bin/launchctl bootout "$domain/$label" 2>/dev/null || true
  rm -f "$plist" "$launcher"
  update_instructions "$HOME/.codex/AGENTS.md" uninstall
  update_instructions "$HOME/.claude/CLAUDE.md" uninstall
  [[ ! -f "$HOME/.codex/AGENTS.override.md" ]] || update_instructions "$HOME/.codex/AGENTS.override.md" uninstall
  rm -f "$binary"
  echo 'Resource Guard removed. Existing unrelated instructions and diagnostic state were preserved.'
  exit 0
fi

[[ -x "$assets_dir/resource-guard" ]] || { echo 'Build the bundled helper with npm run build:resource-guard first.' >&2; exit 1; }
mkdir -p "$support" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
chmod 700 "$support"
/bin/launchctl bootout "$domain/$label" 2>/dev/null || true
cp "$assets_dir/resource-guard" "$binary.new"
chmod 700 "$binary.new"
mv -f "$binary.new" "$binary"
ln -sfn "$binary" "$launcher"

/usr/bin/plutil -create xml1 "$plist.new"
/usr/bin/plutil -insert Label -string "$label" "$plist.new"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$plist.new"
/usr/bin/plutil -insert ProgramArguments.0 -string "$binary" "$plist.new"
/usr/bin/plutil -insert ProgramArguments.1 -string serve "$plist.new"
/usr/bin/plutil -insert RunAtLoad -bool YES "$plist.new"
/usr/bin/plutil -insert KeepAlive -bool YES "$plist.new"
/usr/bin/plutil -insert ThrottleInterval -integer 10 "$plist.new"
# Only fatal coordinator errors go to launchd's stderr; no command output or environment is stored.
/usr/bin/plutil -insert StandardErrorPath -string "$support/service-error.log" "$plist.new"
mv -f "$plist.new" "$plist"
/bin/launchctl bootstrap "$domain" "$plist"
for attempt in 1 2 3 4 5; do
  if "$binary" status --json >/dev/null 2>&1; then break; fi
  sleep 1
done
"$binary" status --json >/dev/null
"$binary" resume
maintenance_acquired=false
update_instructions "$HOME/.codex/AGENTS.md" install
update_instructions "$HOME/.claude/CLAUDE.md" install
[[ ! -f "$HOME/.codex/AGENTS.override.md" ]] || update_instructions "$HOME/.codex/AGENTS.override.md" install
echo 'Resource Guard installed and running. Global Codex and Claude Code instructions updated; existing sessions can read them without restarting.'

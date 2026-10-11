#!/bin/bash
# `version` reads no hosts, policy, or probe, so it is answered before Perl starts.
if [ "$#" -eq 1 ] && [ "$1" = version ]; then echo 4; exit 0; fi
# Root never accepts environment-selected hosts, policy, clock, or executable paths.
if [ "$EUID" -eq 0 ]; then
  target=/etc/hosts
  probe=/Library/PrivilegedHelperTools/productivity-os/focus-probe
else
  target=${HOSTS_FILE:-/etc/hosts}
  probe=${FOCUS_PROBE:-"$(cd "$(dirname "$0")" && pwd)/focus-probe"}
fi
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/perl - "$target" "$probe" "$@" <<'PERL'
use strict;
use warnings;
use utf8;
use Fcntl qw(:DEFAULT :flock SEEK_SET);
use JSON::PP;
use Time::HiRes qw(time clock_gettime CLOCK_UPTIME_RAW);
my ($path, $probe, $op, @args) = @ARGV;
my $json = JSON::PP->new->canonical->utf8;
sub fail { print STDERR $json->encode({code=>$_[1] // 'INVALID_REQUEST', message=>$_[0]})."\n"; exit 2 }
sub is_domain { my ($d)=@_; defined($d) && !ref($d) && length($d)<=253 && $d =~ /\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/ }
sub domain { fail('invalid domain') unless is_domain($_[0]) }
sub tag { fail('invalid tag') unless defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[a-z][a-z0-9_-]{0,31}\z/ && $_[0] ne 'focus' && (!$_[1] || $_[0] ne 'pomodoro') }
sub whole { defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[0-9]+\z/ && $_[0] >= $_[1] && $_[0] <= $_[2] }
sub integer { fail("$_[3] must be $_[1]–$_[2] whole numbers") unless whole(@_) }
sub label { utf8::decode($_[0]) or fail('session label must be valid UTF-8'); fail('invalid session label') if length($_[0]) > 100 || $_[0] =~ /[\r\n\x00-\x1f]/ }
sub monitor { fail('invalid monitor identifier') unless defined($_[0]) && $_[0] =~ /\A[a-zA-Z0-9_-]{1,80}\z/ }
sub durations { integer($_[0],1,1440,'focus minutes'); integer($_[1],1,240,'short break minutes'); integer($_[2],1,240,'long break minutes'); integer($_[3],1,12,'rounds per set') }
my %removal_arity = (remove=>1, 'remove-tag'=>2, 'remove-all-with-tag'=>1, 'remove-everything'=>0, 'end-focus'=>0, 'end-pomodoro'=>0);
sub validate_removal {
  my ($values)=@_;
  fail('invalid unblock operation') unless ref($values) eq 'ARRAY' && @$values && !grep { !defined($_) || ref($_) } @$values;
  my ($command,@values)=@$values;
  fail('invalid unblock operation') unless exists($removal_arity{$command}) && @values == $removal_arity{$command};
  domain($values[0]) if $command eq 'remove' || $command eq 'remove-tag';
  tag($values[1],0) if $command eq 'remove-tag'; tag($values[0],0) if $command eq 'remove-all-with-tag';
}
my %arity = (version=>0,status=>0,list=>0,session=>0,expire=>0,flush=>0,'repair-state'=>0,'pomodoro-status'=>0,'pomodoro-checkpoint'=>1,
  'pomodoro-pause'=>2,'pomodoro-resume'=>1,'pomodoro-next'=>5,'pomodoro-stop'=>0,'confirm-unblock'=>2,%removal_arity);
fail('unknown command or wrong arguments') unless defined($op) && ((exists($arity{$op}) && @args == $arity{$op})
  || ($op eq 'add' && @args==2) || ($op eq 'add-many' && @args>=2) || ($op eq 'start-focus' && @args>=3)
  || ($op eq 'start-pomodoro' && @args>=6) || ($op eq 'request-unblock' && @args>=1));
if ($op eq 'version') { print "4\n"; exit }
if ($op eq 'add') { domain($args[0]); tag($args[1],1) }
if ($op eq 'add-many') { tag($args[0],1); domain($_) for @args[1..$#args] }
validate_removal([$op,@args]) if exists($removal_arity{$op});
if ($op eq 'start-focus') { integer($args[0],1,1440,'duration'); label($args[1]); domain($_) for @args[2..$#args] }
if ($op eq 'start-pomodoro') {
  durations(@args[0..3]); label($args[4]); domain($_) for @args[5..$#args];
  my %unique=map { $_=>1 } @args[5..$#args];
  fail('A Pomodoro can protect at most 200 domains.') if keys(%unique)>200;
}
monitor($args[0]) if $op =~ /\Apomodoro-(?:checkpoint|pause|resume|next)\z/;
fail('invalid pause reason') if $op eq 'pomodoro-pause' && $args[1] ne 'manual' && $args[1] ne 'away';
durations(@args[1..4]) if $op eq 'pomodoro-next';
my $requested;
if ($op eq 'request-unblock') {
  if ($args[0] eq 'batch') {
    fail('invalid unblock batch') unless @args==2 && length($args[1])<=65536;
    $requested=eval { decode_json($args[1]) };
    fail('invalid unblock batch') unless ref($requested) eq 'ARRAY' && @$requested && @$requested<=200;
  } else { $requested=[[@args]] }
  validate_removal($_) for @$requested;
  # Ending a stalled round is its own reviewed decision, never one item of a batch.
  fail('End a stalled Pomodoro round on its own, not in a batch.') if $args[0] eq 'batch' && grep { $_->[0] eq 'end-pomodoro' } @$requested;
}
if ($op eq 'confirm-unblock') {
  fail('invalid unblock identifier') unless $args[0] =~ /\A[0-9a-f]{32}\z/;
  utf8::decode($args[1]) or fail('reason must be valid UTF-8');
  fail('Write a short reason before unblocking.','REASON_REQUIRED') unless $args[1] =~ /\S/ && length($args[1])<=500 && $args[1] !~ /[\x00-\x08\x0b\x0c\x0e-\x1f]/;
}
fail('root must use /etc/hosts') if $>==0 && $path ne '/etc/hosts';
fail('use setup or HOSTS_FILE for testing') if $>!=0 && $path eq '/etc/hosts';
my $state_path=$>==0 ? '/Library/PrivilegedHelperTools/productivity-os/state.json' : "$path.state.json";
my $owner=$<;
if ($>==0) {
  open(my $input,'<','/Library/PrivilegedHelperTools/productivity-os/owner-uid') or fail('Run Setup to install the focus owner.','SETUP_REQUIRED');
  my $value=<$input> // ''; close($input); chomp($value);
  fail('invalid installed focus owner','SETUP_REQUIRED') unless $value =~ /\A[0-9]+\z/ && $value>0;
  $owner=0+$value;
}
# Keep one lock for policy and hosts, including multi-site unblock transactions. The lock wait
# (4 s) plus the probe (2 s) stays inside the Pomodoro (8 s) and Raycast (15 s) client timeouts.
sysopen(my $fh,$path,O_RDWR|O_NOFOLLOW) or fail("open hosts: $!",'IO_ERROR');
$SIG{ALRM}=sub { fail('timed out waiting for hosts lock','BUSY') };
alarm 4; flock($fh,LOCK_EX) or fail("lock hosts: $!",'IO_ERROR'); alarm 0;
binmode $fh; local $/;
my $original=<$fh> // '';
my ($begin,$end)=('# >>> productivity-os >>>','# <<< productivity-os <<<');
my ($old_begin,$old_end)=('# >>> site-blocker >>>','# <<< site-blocker <<<');
my ($from,$to)=($begin,$end);
my @begins=$original =~ /^\Q$from\E\r?$/mg; my @ends=$original =~ /^\Q$to\E\r?$/mg;
my $legacy=$original =~ /^(?:\Q$old_begin\E|\Q$old_end\E)\r?$/m;
fail('both site-blocker and productivity-os hosts markers are present; merge them by hand') if $legacy && (@begins || @ends);
if ($legacy) { ($from,$to)=($old_begin,$old_end); @begins=$original =~ /^\Q$from\E\r?$/mg; @ends=$original =~ /^\Q$to\E\r?$/mg }
my ($prefix,$body,$suffix)=($original,'',''); my $exists=@begins || @ends;
if ($exists) {
  fail('malformed or duplicate hosts markers; repair them before continuing') unless @begins==1 && @ends==1;
  fail('reversed hosts markers') unless $original =~ /\A(.*?)^\Q$from\E\r?\n(.*?)^\Q$to\E\r?(?:\n|\z)(.*)\z/ms;
  ($prefix,$body,$suffix)=($1,$2,$3);
}
my (%entries,@extra,$session);
for my $line (split /\n/,$body) {
  if ($line =~ /\A(?:127\.0\.0\.1|::1)\s+(\S+)\s*(?:#\s*(\S+))?\s*\z/) {
    my ($d,$t)=($1,$2 // 'manual');
    fail("unrecognized entry inside the productivity-os section of $path; remove it by hand: $line") unless is_domain($d) && $t =~ /\A[a-z][a-z0-9_-]{0,31}\z/;
    $entries{$d}{$t}=1;
  } elsif ($line =~ /\A# focus-session (.+)\z/) {
    fail('duplicate focus metadata') if $session;
    $session=eval { decode_json($1) };
    fail('invalid focus metadata') unless ref($session) eq 'HASH' && ($session->{endsAt} // '') =~ /\A[0-9]+\z/ && !ref($session->{label});
  } elsif ($line =~ /\A\s*(?:#.*)?\z/) { push @extra,$line }
  else { fail("unrecognized entry inside the productivity-os section of $path; remove it by hand: $line") }
}
# Returns the object, undef when the file is absent, or '' when it is not a readable JSON object.
sub read_json_file {
  my ($file,$private)=@_; my @stat=lstat($file); return undef unless @stat;
  fail('Unsafe policy file; repair the installation.','STATE_INVALID') if -l _ || !-f _ || ($private && ($stat[4]!=0 || ($stat[2]&0077)));
  return '' if $stat[7]>1048576;
  sysopen(my $input,$file,O_RDONLY|O_NOFOLLOW) or fail("read state: $!",'IO_ERROR'); my $text=<$input>; close($input);
  my $value=eval { decode_json($text // '') }; return ref($value) eq 'HASH' ? $value : '';
}
sub valid_plan {
  my ($v)=@_;
  return ref($v) eq 'HASH' && ($v->{phase}//'') =~ /\A(?:focus|shortBreak|longBreak|ready)\z/ && whole($v->{remainingMs},0,1e15)
    && ref($v->{domains}) eq 'ARRAY' && @{$v->{domains}} && @{$v->{domains}}<=200 && !grep({ !is_domain($_) } @{$v->{domains}}) && defined($v->{label}) && !ref($v->{label})
    && whole($v->{focusMinutes},1,1440) && whole($v->{shortBreakMinutes},1,240) && whole($v->{longBreakMinutes},1,240) && whole($v->{roundsPerSet},1,12) && whole($v->{completedRounds},0,1000000)
    && ($v->{phase} eq 'focus' || $v->{phase} eq 'ready' || $v->{paused} || whole($v->{breakEndsAt},0,1e15));
}
# Degraded mode: a policy that is damaged, unsupported, or missing while Pomodoro blocks exist is
# never trusted or rewritten. Reads, additions, and expiry keep working without a plan; everything
# else fails closed until repair-state rebuilds it. Unsafe files (links, permissions) always fail.
my $state=read_json_file($state_path,$>==0); my $state_exists=defined($state);
my $damage=!$state_exists ? ((grep { $entries{$_}{pomodoro} } keys %entries) ? 'Pomodoro state is missing; existing blocks were preserved.' : undef)
  : !ref($state) ? 'Policy state is damaged; existing blocks were preserved.'
  : !whole($state->{schema},3,3) || !whole($state->{ownerUID},$owner,$owner) ? 'Unsupported policy state; existing blocks were preserved.'
  : defined($state->{pomodoro}) && !valid_plan($state->{pomodoro}) ? 'Invalid Pomodoro state; existing blocks were preserved.' : undef;
fail($damage,'STATE_INVALID') if $damage && !grep { $op eq $_ } qw(version status list session expire add add-many flush repair-state);
$state={schema=>3,ownerUID=>$owner} if $damage || !$state_exists;
my $save_state=!$damage; my $before_state=$json->encode($state); my $sample;
sub sample {
  return $sample if $sample;
  if ($>!=0 && -e "$path.clock.json") { $sample=read_json_file("$path.clock.json",0) or fail('The test clock is damaged.','STATE_INVALID') }
  elsif (-x $probe) {
    # Kill and reap a stuck probe: closing its pipe would otherwise wait for it indefinitely.
    my ($pid,$pipe);
    local $SIG{ALRM}=sub { if ($pid) { kill('KILL',$pid); waitpid($pid,0); $pid=0 } die "probe timeout\n" };
    my $output=eval { alarm 2; $pid=open($pipe,'-|',$probe,"$owner") or die "probe unavailable\n"; my $data=<$pipe>; close($pipe) or die "probe failed\n"; $pid=0; alarm 0; $data };
    alarm 0; $sample=eval { decode_json($output // '') };
  }
  if (ref($sample) ne 'HASH' || !defined($sample->{bootID}) || ref($sample->{bootID}) || $sample->{bootID} !~ /\A[a-zA-Z0-9_-]{1,80}\z/
    || !defined($sample->{uptimeMs}) || ref($sample->{uptimeMs}) || $sample->{uptimeMs} !~ /\A[0-9]+(?:\.[0-9]+)?\z/) {
    $sample={bootID=>'unknown',uptimeMs=>int(clock_gettime(CLOCK_UPTIME_RAW)*1000),unlocked=>JSON::PP::false,available=>JSON::PP::false};
  }
  $sample->{available}=JSON::PP::true unless exists($sample->{available});
  $sample->{unlocked}=$sample->{unlocked} && $sample->{available} ? JSON::PP::true : JSON::PP::false; return $sample;
}
sub now_ms {
  if ($>!=0 && -e "$path.clock.json") { my $s=sample(); return int($s->{wallMs}) if defined($s->{wallMs}) && !ref($s->{wallMs}) && $s->{wallMs} =~ /\A[0-9]+(?:\.[0-9]+)?\z/ }
  return int(time*1000);
}
my $now=now_ms(); my $changed=$legacy ? 1 : 0;
sub remove_tag { my ($t)=@_; for my $d (keys %entries) { $changed=1 if delete $entries{$d}{$t}; delete $entries{$d} unless keys %{$entries{$d}} } }
if ($session && $session->{endsAt}<=$now) { remove_tag('focus'); $session=undef; $changed=1 }
my $p=$state->{pomodoro};
# A finished round does not silently undo a deliberate, reviewed unblock. The
# selected targets remain saved and are restored only for the next explicit round.
if ($p && $p->{phase} eq 'focus' && $p->{remainingMs}>0) {
  for my $d (@{$p->{domains}}) { unless ($entries{$d}{pomodoro}) { $entries{$d}{pomodoro}=1; $changed=1 } }
}
# A running break follows its wall-clock deadline: replies derive the time left, and only the
# transition to ready is saved, so reads during a break never rewrite the policy.
sub break_running { $p && $p->{phase} ne 'focus' && $p->{phase} ne 'ready' && !$p->{paused} }
sub remaining { break_running() ? int($p->{breakEndsAt}>$now ? $p->{breakEndsAt}-$now : 0) : $p->{remainingMs} }
sub reconcile {
  return unless $p;
  if ($p->{phase} eq 'focus') {
    my $s=sample(); my $last=$p->{checkpoint};
    my $valid=ref($last) eq 'HASH' && ($last->{bootID}//'') eq $s->{bootID} && defined($last->{uptimeMs}) && $s->{uptimeMs}>=$last->{uptimeMs} && $s->{uptimeMs}-$last->{uptimeMs}<=15000;
    if (!$s->{unlocked} || !$valid) { $p->{paused}=JSON::PP::true; $p->{pauseReason}=!$s->{unlocked} && $s->{available} ? 'away' : 'monitor' unless ($p->{pauseReason}//'') eq 'manual' }
  } elsif (break_running() && $p->{breakEndsAt}<=$now) {
    $p->{phase}='ready'; $p->{remainingMs}=0; $p->{paused}=JSON::PP::false; delete @$p{qw(breakEndsAt pauseReason stall)};
  }
}
reconcile();
# Safety valve for a round that cannot progress (for example, after Health Breaks dies): only the
# LaunchDaemon's expire run measures how long focus stays paused, for any reason except a manual
# pause, while the owner is present (unlocked, on the console, input within 5 minutes). Each run
# adds at most one minute of the same boot's uptime; 30 minutes mark the round stalled.
sub accrued { my $v=$p && $p->{stall}; ref($v) eq 'HASH' && whole($v->{accruedMs},0,1e15) ? ($v->{accruedMs}<1800000 ? 0+$v->{accruedMs} : 1800000) : 0 }
sub stalled { $p && $p->{phase} eq 'focus' && $p->{remainingMs}>0 && accrued()>=1800000 }
if ($op eq 'expire' && $p && $p->{phase} eq 'focus') {
  my $s=sample(); my $v=$p->{stall}; my $total=accrued(); my $idle=$s->{idleMs};
  my $present=$s->{unlocked} && defined($idle) && !ref($idle) && $idle =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $idle<=300000;
  if ($present && $p->{paused} && ($p->{pauseReason}//'') ne 'manual' && $total<1800000) {
    my $since=ref($v) eq 'HASH' && ($v->{bootID}//'') eq $s->{bootID} && defined($v->{uptimeMs}) && !ref($v->{uptimeMs})
      && $v->{uptimeMs} =~ /\A[0-9]+(?:\.[0-9]+)?\z/ && $s->{uptimeMs}>=$v->{uptimeMs} ? $s->{uptimeMs}-$v->{uptimeMs} : 0;
    $total=int($total+($since<60000 ? $since : 60000)); $total=1800000 if $total>1800000;
    $p->{stall}=$total<1800000 ? {bootID=>$s->{bootID},uptimeMs=>0+$s->{uptimeMs},accruedMs=>$total} : {accruedMs=>$total};
  } elsif ($total) { $p->{stall}={accruedMs=>$total} } else { delete $p->{stall} }
}
sub session_locked { $session && $session->{endsAt}>$now }
sub hard_locked { session_locked() || ($p && $p->{phase} eq 'focus' && $p->{remainingMs}>0) }
# Ending a stalled round ($_[0]) skips only the Pomodoro lock; a focus session still holds.
sub require_unlocked { fail('Finish the current focus round before changing website protection.','FOCUS_LOCKED') if $_[0] ? session_locked() : hard_locked() }
sub checkpoint {
  my ($id,$resume_manual,$attach_only)=@_; return unless $p && $p->{phase} eq 'focus';
  my $s=sample(); my $last=$p->{checkpoint};
  my $same=ref($last) eq 'HASH' && ($last->{monitorID}//'') eq $id && ($last->{bootID}//'') eq $s->{bootID};
  my $delta=$same ? $s->{uptimeMs}-$last->{uptimeMs} : 0;
  if (!$attach_only && !$p->{paused} && $s->{unlocked} && $same && $delta>=0 && $delta<=15000 && $last->{unlocked}) {
    $p->{remainingMs}=int($p->{remainingMs}>$delta ? $p->{remainingMs}-$delta : 0); delete $p->{stall} if $delta>0;
  }
  $p->{checkpoint}={monitorID=>$id,bootID=>$s->{bootID},uptimeMs=>0+$s->{uptimeMs},unlocked=>$s->{unlocked}};
  if ($p->{remainingMs}==0) {
    $p->{completedRounds}+=1; $p->{phase}=$p->{completedRounds}%$p->{roundsPerSet}==0 ? 'longBreak' : 'shortBreak';
    $p->{remainingMs}=($p->{phase} eq 'longBreak' ? $p->{longBreakMinutes} : $p->{shortBreakMinutes})*60000;
    $p->{breakEndsAt}=$now+$p->{remainingMs}; $p->{paused}=JSON::PP::false; delete @$p{qw(pauseReason checkpoint stall)};
  } elsif (!$s->{unlocked}) {
    $p->{paused}=JSON::PP::true; $p->{pauseReason}=$s->{available} ? 'away' : 'monitor' unless ($p->{pauseReason}//'') eq 'manual';
  } elsif (($p->{pauseReason}//'') ne 'manual' || $resume_manual) { $p->{paused}=JSON::PP::false; delete $p->{pauseReason} }
}
sub public_pomodoro {
  return undef unless $p; my %r=map { $_=>$p->{$_} } qw(phase focusMinutes shortBreakMinutes longBreakMinutes roundsPerSet completedRounds label domains);
  $r{remainingMs}=remaining(); $r{paused}=$p->{paused} ? JSON::PP::true : JSON::PP::false; $r{pauseReason}=$p->{pauseReason} if $p->{paused};
  $r{stalled}=stalled() ? JSON::PP::true : JSON::PP::false;
  $r{endsAt}=$p->{paused} || $p->{phase} eq 'ready' ? undef : $p->{phase} eq 'focus' ? $now+$p->{remainingMs} : $p->{breakEndsAt}; return \%r;
}
sub snapshot_scope {
  my ($operations)=@_; my %scope;
  for my $operation (@$operations) {
    my ($c,@v)=@$operation;
    for my $d (keys %entries) { for my $t (keys %{$entries{$d}}) {
      $scope{"$d\t$t"}=1 if $c eq 'remove-everything' || ($c eq 'remove' && $d eq $v[0]) || ($c eq 'remove-tag' && $d eq $v[0] && $t eq $v[1]) || ($c eq 'remove-all-with-tag' && $t eq $v[0]) || ($c eq 'end-focus' && $t eq 'focus');
    } }
    $scope{"pomodoro\tstalled"}=1 if $c eq 'end-pomodoro' && stalled();
  }
  return [sort keys %scope];
}
sub execute_removal {
  my ($c,@v)=@{$_[0]};
  if ($c eq 'remove') { $changed=1 if delete $entries{$v[0]} }
  elsif ($c eq 'remove-tag') { if ($entries{$v[0]}) { $changed=1 if delete $entries{$v[0]}{$v[1]}; delete $entries{$v[0]} unless keys %{$entries{$v[0]}} } }
  elsif ($c eq 'remove-all-with-tag') { remove_tag($v[0]) }
  elsif ($c eq 'end-focus') { remove_tag('focus'); $changed=1 if $session; $session=undef }
  elsif ($c eq 'end-pomodoro') { $state->{pomodoro}=undef; $p=undef }
  elsif ($c eq 'remove-everything') { %entries=(); $session=undef; @extra=(); $changed=$exists }
}
my ($output,$set_aside);
if ($op eq 'add' || $op eq 'add-many') {
  my ($t,@domains)=$op eq 'add' ? ($args[1],$args[0]) : @args;
  for my $d (@domains) { $changed=1 unless $entries{$d}{$t}; $entries{$d}{$t}=1 }
} elsif (exists($removal_arity{$op})) { require_unlocked($op eq 'end-pomodoro' && stalled()); fail('Wait 60 seconds and give a reason before unblocking.','UNLOCK_REQUIRED') }
elsif ($op eq 'request-unblock') {
  my $ending=$requested->[0][0] eq 'end-pomodoro'; require_unlocked($ending);
  fail('Only a Pomodoro round that has made no progress for 30 minutes while you were present can be ended early.','NOT_STALLED') if $ending && !stalled();
  my $scope=snapshot_scope($requested); my $s=sample();
  fail('The system clock is unavailable. Try again.','CLOCK_UNAVAILABLE') unless $s->{available};
  my $r=$state->{pendingUnlock};
  if (!(ref($r) eq 'HASH' && ($r->{bootID}//'') eq $s->{bootID} && $now<($r->{expiresAt}//0)
      && $s->{uptimeMs}>=($r->{requestedUptimeMs}//0) && $s->{uptimeMs}-($r->{requestedUptimeMs}//0)<180000
      && $json->encode($r->{operations}) eq $json->encode($requested) && $json->encode($r->{scope}) eq $json->encode($scope))) {
    sysopen(my $random,'/dev/urandom',O_RDONLY) or fail('Could not create unblock request.','IO_ERROR');
    read($random,my $bytes,16)==16 or fail('Could not create unblock request.','IO_ERROR'); close($random);
    my %sites=map { (split /\t/,$_)[0]=>1 } @$scope;
    $r={id=>unpack('H*',$bytes),readyAt=>$now+60000,expiresAt=>$now+180000,
      description=>$ending ? 'End the stalled Pomodoro round (site blocks stay)' : keys(%sites) ? 'Unblock '.join(', ',sort keys %sites) : 'Remove the requested website blocks',
      operations=>$requested,scope=>$scope,bootID=>$s->{bootID},requestedUptimeMs=>$s->{uptimeMs}};
    $state->{pendingUnlock}=$r;
  }
  $output={map { $_=>$r->{$_} } qw(id readyAt expiresAt description)};
} elsif ($op eq 'confirm-unblock') {
  my $r=$state->{pendingUnlock}; my $current=ref($r) eq 'HASH' && ($r->{id}//'') eq $args[0];
  # The stalled-round review bypasses the Pomodoro lock; the stall itself is re-checked with the scope.
  my $ending=$current && ref($r->{operations}) eq 'ARRAY' && $json->encode($r->{operations}) eq '[["end-pomodoro"]]';
  require_unlocked($ending);
  fail('This unblock request is no longer available. Start again.','UNLOCK_EXPIRED') unless $current;
  my $s=sample();
  fail('This unblock request expired. Start again.','UNLOCK_EXPIRED') unless $s->{available} && ($r->{bootID}//'') eq $s->{bootID} && $now<$r->{expiresAt} && $s->{uptimeMs}>=$r->{requestedUptimeMs} && $s->{uptimeMs}-$r->{requestedUptimeMs}<180000;
  fail('The 60-second wait is still running.','UNLOCK_NOT_READY') unless $now>=$r->{readyAt} && $s->{uptimeMs}-$r->{requestedUptimeMs}>=60000;
  validate_removal($_) for @{$r->{operations}};
  fail($ending ? 'The round is making progress again, so it was not ended.' : 'These blocks changed. Start a fresh unblock request.','UNLOCK_CHANGED')
    unless $json->encode(snapshot_scope($r->{operations})) eq $json->encode($r->{scope});
  execute_removal($_) for @{$r->{operations}};
  delete $state->{pendingUnlock}; $output={unblocked=>JSON::PP::true};
} elsif ($op eq 'start-focus') {
  require_unlocked(); fail('Stop the Pomodoro before starting a different timer.','POMODORO_ACTIVE') if $p;
  remove_tag('focus'); $entries{$_}{focus}=1 for @args[2..$#args]; $session={endsAt=>$now+$args[0]*60000,label=>$args[1]}; delete $state->{pendingUnlock}; $changed=1;
} elsif ($op eq 'start-pomodoro') {
  require_unlocked(); fail('Stop the current Pomodoro before starting another.','POMODORO_ACTIVE') if $p;
  my %seen; my @domains=grep { !$seen{$_}++ } @args[5..$#args];
  $p={phase=>'focus',paused=>JSON::PP::true,pauseReason=>'monitor',remainingMs=>$args[0]*60000,focusMinutes=>0+$args[0],shortBreakMinutes=>0+$args[1],longBreakMinutes=>0+$args[2],roundsPerSet=>0+$args[3],completedRounds=>0,label=>$args[4],domains=>\@domains};
  $state->{pomodoro}=$p; delete $state->{pendingUnlock}; $entries{$_}{pomodoro}=1 for @domains; $changed=1;
} elsif ($op eq 'pomodoro-checkpoint') { checkpoint($args[0],0,0) }
elsif ($op eq 'pomodoro-pause') {
  if ($p && $p->{phase} eq 'focus') {
    checkpoint($args[0],0,0);
    if ($p->{phase} eq 'focus') { $p->{paused}=JSON::PP::true; $p->{pauseReason}=$args[1] unless $args[1] eq 'away' && ($p->{pauseReason}//'') eq 'manual' }
  } elsif ($p && $p->{phase} ne 'ready' && $args[1] eq 'manual') { $p->{remainingMs}=remaining(); $p->{paused}=JSON::PP::true; $p->{pauseReason}='manual'; delete $p->{breakEndsAt} }
} elsif ($op eq 'pomodoro-resume') {
  if ($p && $p->{phase} eq 'focus') { checkpoint($args[0],1,1) }
  elsif ($p && $p->{phase} ne 'ready' && $p->{paused}) { $p->{paused}=JSON::PP::false; delete $p->{pauseReason}; $p->{breakEndsAt}=$now+$p->{remainingMs} }
} elsif ($op eq 'pomodoro-next') {
  fail('Finish the break before starting the next round.','NOT_READY') unless $p && $p->{phase} eq 'ready';
  @$p{qw(focusMinutes shortBreakMinutes longBreakMinutes roundsPerSet)}=map { 0+$_ } @args[1..4];
  for my $d (@{$p->{domains}}) { unless ($entries{$d}{pomodoro}) { $entries{$d}{pomodoro}=1; $changed=1 } }
  $p->{phase}='focus'; $p->{remainingMs}=$p->{focusMinutes}*60000; $p->{paused}=JSON::PP::true; $p->{pauseReason}='monitor'; delete $p->{stall}; delete $state->{pendingUnlock}; checkpoint($args[0],1,1);
} elsif ($op eq 'pomodoro-stop') { require_unlocked(); $state->{pomodoro}=undef; $p=undef }
elsif ($op eq 'repair-state') {
  # Only a degraded policy is rebuilt: the damaged file is kept aside, and the Pomodoro blocks get a
  # paused recovery round that resumes once Health Breaks reattaches. Site blocks never change.
  if ($damage) {
    my @domains=sort grep { $entries{$_}{pomodoro} } keys %entries; splice(@domains,200) if @domains>200;
    $state={schema=>3,ownerUID=>$owner}; $p=undef;
    $p=$state->{pomodoro}={phase=>'focus',paused=>JSON::PP::true,pauseReason=>'monitor',remainingMs=>1500000,focusMinutes=>25,shortBreakMinutes=>5,longBreakMinutes=>15,
      roundsPerSet=>4,completedRounds=>0,label=>'Recovered Pomodoro',domains=>\@domains} if @domains;
    ($save_state,$before_state,$set_aside)=(1,'',$state_exists);
  } else { $save_state=0 }
  $output={repaired=>$damage ? JSON::PP::true : JSON::PP::false};
}
# Metadata checkpoints do not rewrite hosts or flush DNS. An interrupted policy/hosts
# transaction can leave extra protection, never an early release of an unfinished round.
# Termination requests are ignored until both files are written (SIGKILL still applies).
{
  local @SIG{qw(TERM INT HUP)}=('IGNORE') x 3;
  my $after_state=$json->encode($state);
  if ($save_state && $after_state ne $before_state) {
    require File::Temp; require IO::Handle;
    my ($saved,$temporary)=eval { File::Temp::tempfile("$state_path.tmp.XXXXXX",UNLINK=>0) };
    fail('Could not create the policy checkpoint.','IO_ERROR') unless $saved;
    eval {
      print {$saved} $after_state or die "write: $!";
      $saved->flush or die "flush: $!"; $saved->sync or die "sync: $!";
      close($saved) or die "close: $!";
      if ($set_aside) { my $aside=my $base="$state_path.damaged-".int($now/1000); my $n=0; $aside="$base-".++$n while lstat($aside); rename($state_path,$aside) or die "set aside: $!" }
      rename($temporary,$state_path) or die "commit: $!"; 1;
    } or do { my $error=$@; unlink($temporary); fail("save state: $error",'IO_ERROR') };
  }
  if ($changed) {
    my $new=$prefix;
    if (%entries || $session || @extra) {
      $new.="\n" if length($new) && $new !~ /\n\z/; $new.="$begin\n"; $new.="$_\n" for @extra;
      $new.='# focus-session '.encode_json($session)."\n" if $session;
      for my $d (sort keys %entries) { for my $t (sort keys %{$entries{$d}}) { $new.="127.0.0.1 $d # $t\n::1 $d # $t\n" } }
      $new.="$end\n";
    }
    $new.=$suffix;
    # Unbuffered writes, then truncate: no partial buffer flush can interleave with old bytes.
    sysseek($fh,0,SEEK_SET) or fail("seek hosts: $!",'IO_ERROR');
    for (my $done=0; $done<length($new);) { my $count=syswrite($fh,$new,length($new)-$done,$done); fail("write hosts: $!",'IO_ERROR') unless $count; $done+=$count }
    truncate($fh,length($new)) or fail("truncate hosts: $!",'IO_ERROR');
  }
}
close($fh) or fail("close hosts: $!",'IO_ERROR');
if (($changed || $op eq 'flush') && $path eq '/etc/hosts') { system('/usr/bin/dscacheutil','-flushcache'); system('/usr/bin/killall','-HUP','mDNSResponder') }
if ($op eq 'list') { print "$_\t".join(',',sort keys %{$entries{$_}})."\n" for sort keys %entries }
elsif ($op eq 'status') {
  print $json->encode({version=>4,session=>$session,pomodoro=>public_pomodoro(),stateDamaged=>$damage ? JSON::PP::true : JSON::PP::false,
    entries=>[map { +{domain=>$_,tag=>join(',',sort keys %{$entries{$_}})} } sort keys %entries]})."\n";
}
elsif ($op eq 'session' || $op eq 'start-focus') { print encode_json($session)."\n" }
elsif ($op eq 'pomodoro-status' || $op eq 'start-pomodoro' || $op =~ /\Apomodoro-(?:checkpoint|pause|resume|next|stop)\z/) { print encode_json(public_pomodoro())."\n" }
elsif (defined($output)) { print encode_json($output)."\n" }
PERL

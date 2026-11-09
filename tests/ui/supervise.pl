#!/usr/bin/perl
# Process-group supervisor for the UI snapshot harness.
#
#   supervise.pl [--rmdir DIR] [--log FILE] [--pause-after-reap MS]
#                [--signal-after FILE --signal SIG] -- CMD ARGS...
#
# Ownership: the supervisor first forks a GUARDIAN, which becomes the leader of a
# new process group (group id = guardian pid) and does nothing but wait for the
# supervisor to close a pipe. CMD is then forked INTO that group. The guardian is
# our own child and we reap it LAST, so its pid, and with it the group id, stays
# pinned (running or zombie) for the whole teardown: `kill SIG, -group` can never
# reach anyone else's group. CMD itself (also our child) can be reaped as soon as
# it exits; that releases nothing. Nothing here, or anywhere in the harness,
# signals a pid number, and nothing is signalled after the guardian is reaped.
#
# Teardown (always; after CMD exits, or on INT/TERM): if any process other than
# the guardian is still in the group, TERM the group, wait up to a grace second,
# KILL the group if any member is left, and wait until none is. Only then close
# the guardian's pipe, reap it, and remove --rmdir. Members are found by reading
# `ps` (observation only: the group id comes from our own fork, never from ps).
# A clean run has no members left when CMD exits, so it signals nothing. The
# guardian ignores INT/TERM/HUP; a group KILL leaves it an (unreaped) zombie,
# which still pins the id. If the supervisor itself is SIGKILLed the guardian
# sees EOF and exits; the parent nvim notices it was orphaned (run.lua).
#
# INT/TERM/CHLD/ALRM are blocked except inside sigsuspend(), so handlers only
# record state.
#
#   --rmdir DIR          remove DIR (exact path) after the group is released
#   --log FILE           append "signal ..." / "reaped" (= group released) /
#                        "leftover ..." lines (self-test evidence)
#   --pause-after-reap MS  linger MS after releasing the group (self-test: a
#                          signal that arrives afterwards must signal nothing)
#   --signal-after FILE --signal SIG [--min-lines N]
#                        once FILE has >= N lines (default 1), send SIG to the
#                        group (self-test driver; same ownership rule)
#
# Exit status: CMD's (128+N if killed by signal N); 128+N if WE got INT/TERM;
# 1 if CMD exited 0 but a member could not be stopped.
use strict;
use warnings;
use POSIX qw(:sys_wait_h :signal_h);
use Time::HiRes qw(ualarm usleep time);

my ( $rmdir, $log, $pause, $after, $after_sig );
my $min_lines = 1;
while ( @ARGV && $ARGV[0] ne '--' ) {
    my $o = shift @ARGV;
    if    ( $o eq '--rmdir' )            { $rmdir     = shift @ARGV }
    elsif ( $o eq '--log' )              { $log       = shift @ARGV }
    elsif ( $o eq '--pause-after-reap' ) { $pause     = shift @ARGV }
    elsif ( $o eq '--signal-after' )     { $after     = shift @ARGV }
    elsif ( $o eq '--signal' )           { $after_sig = shift @ARGV }
    elsif ( $o eq '--min-lines' )        { $min_lines = shift @ARGV }
    else                                 { die "supervise.pl: unknown option $o\n" }
}
shift @ARGV;
die "supervise.pl: no command\n" unless @ARGV;

sub note {
    return unless $log;
    open( my $fh, '>>', $log ) or return;
    print $fh "$_[0]\n";
    close $fh;
}

my $caught;
$SIG{INT}  = sub { $caught ||= 'INT' };
$SIG{TERM} = sub { $caught ||= 'TERM' };
$SIG{CHLD} = sub { };
$SIG{ALRM} = sub { };
my $mask = POSIX::SigSet->new( SIGINT, SIGTERM, SIGCHLD, SIGALRM );
sigprocmask( SIG_BLOCK, $mask ) or die "sigprocmask: $!\n";
my $none = POSIX::SigSet->new();

# the run's own pid, so the child can tell it has been orphaned (run.lua)
$ENV{OBELUS_UI_SUPERVISOR_PID} = $$;

# the guardian: group leader, holds the group id until we reap it
pipe( my $hold_r, my $hold_w ) or die "pipe: $!\n";    # both close-on-exec
my $grp = fork() // die "fork: $!\n";
if ( $grp == 0 ) {
    close $hold_w;
    $SIG{$_} = 'IGNORE' for qw(INT TERM HUP QUIT PIPE);
    $SIG{$_} = 'DEFAULT' for qw(CHLD ALRM);
    sigprocmask( SIG_SETMASK, $none );
    POSIX::setpgid( 0, 0 );
    my $buf;
    while (1) {    # until the supervisor closes the pipe (or dies)
        my $n = sysread( $hold_r, $buf, 1 );
        last if defined $n && $n == 0;
        last if !defined $n && !$!{EINTR};
    }
    POSIX::_exit(0);
}
close $hold_r;
POSIX::setpgid( $grp, $grp );    # also from here: the group exists before CMD joins it

my $pid = fork() // die "fork: $!\n";
if ( $pid == 0 ) {
    sigprocmask( SIG_SETMASK, $none );
    $SIG{$_} = 'DEFAULT' for qw(INT TERM CHLD ALRM);
    POSIX::setpgid( 0, $grp ) or POSIX::_exit(127);    # never run outside the group
    exec { $ARGV[0] } @ARGV or POSIX::_exit(127);
}
POSIX::setpgid( $pid, $grp );

sub lines {
    open( my $fh, '<', $_[0] ) or return 0;
    my $n = 0;
    $n++ while <$fh>;
    close $fh;
    return $n;
}

my ( $exited, $status ) = ( 0, 0 );    # CMD reaped?
my $released = 0;                      # guardian reaped: never signal again
my $fired    = 0;

sub try_reap_cmd {
    return 1 if $exited;
    my $r = waitpid( $pid, WNOHANG );
    if ( $r == $pid ) { ( $exited, $status ) = ( 1, $? ); }
    return $exited;
}

sub group_signal {
    my ($sig) = @_;
    return if $released;    # ownership rule: never after the guardian is reaped
    note("signal $sig");
    kill( $sig, -$grp );
}

sub wait_tick {             # sleep until a signal or ~100 ms, signals blocked otherwise
    ualarm(100_000);
    sigsuspend($none);
    ualarm(0);
}

# live members of the group other than the guardian (zombies excluded: they
# cannot run, and ours are reaped here). undef if ps could not be read.
sub members {
    try_reap_cmd();
    open( my $ps, '-|', 'ps', '-A', '-o', 'pid=', '-o', 'pgid=', '-o', 'stat=' ) or return undef;
    my @m;
    while (<$ps>) {
        my ( $p, $g, $s ) = split;
        next unless defined $s && $g =~ /^\d+$/ && $g == $grp && $p != $grp;
        next if $s =~ /^Z/;
        push @m, $p;
    }
    close $ps or return undef;
    return scalar @m;
}

sub empty { my $n = members(); return defined $n && $n == 0 }

my $leftover = 0;

sub teardown {
    return if empty();
    group_signal('TERM');
    for ( 1 .. 10 ) {    # ~1 s grace
        wait_tick();
        return if empty();
    }
    group_signal('KILL');
    for ( 1 .. 100 ) {    # up to ~10 s for the kernel to finish them
        return if empty();
        wait_tick();
    }
    $leftover = 1;
    note("leftover");
    print STDERR "supervise.pl: process group $grp still has members after KILL\n";
}

while (1) {
    if ($caught) { last }
    if ( try_reap_cmd() ) { last }
    if ( $after && !$fired && lines($after) >= $min_lines ) {
        usleep(500_000);
        group_signal($after_sig);
        $fired = 1;
        next;
    }
    wait_tick();
}

teardown();
if ( !try_reap_cmd() ) {    # it was a member, so it is gone (KILLed if need be)
    waitpid( $pid, 0 );
    ( $exited, $status ) = ( 1, $? );
}
close $hold_w;                                # the guardian exits on EOF
waitpid( $grp, 0 );                           # release the group id: last
$released = 1;
note("reaped");

if ($pause) {
    my $until = time + $pause / 1000;
    wait_tick() while time < $until;
}

if ( defined $rmdir && -e $rmdir ) {
    system( 'rm', '-rf', '--', $rmdir );
}

if ($caught) {
    exit( 128 + ( $caught eq 'INT' ? 2 : 15 ) );
}
my $rc = ( $status & 127 ) ? 128 + ( $status & 127 ) : ( $status >> 8 );
exit( $rc == 0 && $leftover ? 1 : $rc );

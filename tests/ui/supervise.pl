#!/usr/bin/perl
# Process-group supervisor for the UI snapshot harness.
#
#   supervise.pl [--rmdir DIR] [--log FILE] [--pause-after-reap MS]
#                [--signal-after FILE --signal SIG] -- CMD ARGS...
#
# Forks CMD into a NEW process group (its pid = the group id) and is the only
# process that ever signals it. Ownership rule: a signal goes to that group ONLY
# while its leader is still unreaped by us. An unreaped child (running or zombie)
# pins its pid, so the group id cannot belong to anyone else. Once the leader is
# reaped we never signal again. Nothing here (or anywhere in the harness) signals
# a pid number read from a file, a variable of a shell, or `ps`.
#
# INT/TERM/CHLD/ALRM are blocked except inside sigsuspend(), so a signal handler
# can never run between "waitpid reaped the leader" and "we noted it": the check
# for an exited leader always comes first, and teardown only runs while it is
# unreaped. Teardown: TERM to the group, a grace second, KILL to the group, then
# reap.
#
#   --rmdir DIR          remove DIR (exact path) after the child is reaped
#   --log FILE           append "reaped" / "signal ..." lines (self-test evidence)
#   --pause-after-reap MS  linger MS after reaping (self-test: a signal that
#                          arrives after the leader exited must signal nothing)
#   --signal-after FILE --signal SIG [--min-lines N]
#                        once FILE has >= N lines (default 1), send SIG to the
#                        child group (self-test driver; same ownership rule)
#
# Exit status: the child's (128+N if killed by signal N); 128+N if WE got INT/TERM.
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

my $pid = fork() // die "fork: $!\n";
if ( $pid == 0 ) {
    sigprocmask( SIG_SETMASK, $none );
    $SIG{$_} = 'DEFAULT' for qw(INT TERM CHLD ALRM);
    setpgrp( 0, 0 );
    exec { $ARGV[0] } @ARGV or POSIX::_exit(127);
}
setpgrp( $pid, $pid );    # also from here: the group exists before we could signal it

sub lines {
    open( my $fh, '<', $_[0] ) or return 0;
    my $n = 0;
    $n++ while <$fh>;
    close $fh;
    return $n;
}

my ( $reaped, $status ) = ( 0, 0 );
my $fired = 0;

sub try_reap {
    return 1 if $reaped;
    my $r = waitpid( $pid, WNOHANG );
    if ( $r == $pid ) { ( $reaped, $status ) = ( 1, $? ); note("reaped"); }
    return $reaped;
}

sub group_signal {
    my ($sig) = @_;
    return if $reaped;    # ownership rule: never after the leader is reaped
    note("signal $sig");
    kill( $sig, -$pid );
}

sub wait_tick {           # sleep until a signal or ~100 ms, signals blocked otherwise
    ualarm(100_000);
    sigsuspend($none);
    ualarm(0);
}

while ( !try_reap() ) {
    if ($caught) {
        group_signal('TERM');
        for ( 1 .. 10 ) { wait_tick(); }    # ~1 s grace (the leader stays unreaped)
        group_signal('KILL');
        waitpid( $pid, 0 );
        ( $reaped, $status ) = ( 1, $? );
        note("reaped");
        last;
    }
    if ( $after && !$fired && lines($after) >= $min_lines ) {
        usleep(500_000);
        group_signal($after_sig);
        $fired = 1;
        next;
    }
    wait_tick();
}

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
exit( ( $status & 127 ) ? 128 + ( $status & 127 ) : ( $status >> 8 ) );

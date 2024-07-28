#!/usr/bin/env perl
# vim: ts=4 sw=4 et ci

use v5.36;
use POSIX ":sys_wait_h";
use File::Spec;
use Socket;
use List::Util;

# Wether to enable built-in simple syslog server or not
use constant SYSLOG_SERVER_ENABLED => 1;

# Syslog message max length
use constant SYSLOG_MSG_MAXLEN => 4096;

# How many seconds to sleep in the event loop
use constant EVENT_LOOP_SLEEP => 1;

# Syslog message to match
use constant SYSLOG_REGEX => qr/<(\d+)>(.*)/;

# Syslog socket path
use constant SYSLOG_SERVER_SOCKET => "/dev/log";

# Where to look for services, templates definitions and bundled modules
use constant PINITO_DIR =>
  File::Spec->join( ( File::Spec->splitpath($0) )[1], "pinito" );

use lib File::Spec->join( PINITO_DIR, "modules" );
use Text::Template;

### Routines
$| = 1;
my $keep_going = 1;

# Signal processing
my %children;
my %forward_signals;
my %quit_signals = (
    'INT'  => 1,
    'QUIT' => 1,
    'TERM' => 1,
);

# Signals to forward to children
# FPE ILL SEGV BUS ABRT TRAP SYS TTIN TTOU and CHLD are not forwarded
use constant FORWARD_SIGNALS_LIST =>
  qw(HUP INT QUIT PIPE ALRM TERM URG STOP TSTP CONT IO XCPU XFSZ VTALRM PROF WINCH USR1 USR2);

sub handle_signal($signal) {
    if ( exists( $forward_signals{$signal} ) ) {
        kill $signal, -getpgrp();
    }

    if ( exists( $quit_signals{$signal} ) ) {
        $keep_going = 0;
    }
}

sub childcare($signal) {
    local ( $!, $? );
    while ( ( my $pid = waitpid -1, WNOHANG ) > 0 ) {
        delete $children{$pid};
    }
}

sub setup_signal_handling() {
    %forward_signals =
      map { $SIG{$_} = \&handle_signal; $_ => 1 } (FORWARD_SIGNALS_LIST);

    # Ensure quit handlers
    foreach ( keys %quit_signals ) { $SIG{$_} = \&handle_signal }

    # SIGCHLD is handled separately
    $SIG{CHLD} = \&childcare;
}

# This avoid dying when a syscall is interrupted by a signal
sub die_unless_eintr($msg) {
    die $msg unless ( $!{EINTR} );
}

## Syslog server
# Arrays to decode syslog facilities/severities
use constant SYSLOG_FACILITIES =>
  qw(kern user mail daemon auth syslog lpr news uucp cron authpriv ftp ntp security console
  solaris-cron local0 local1 local2 local3 local4 local5 local6 local7);
use constant SYSLOG_SEVERITIES =>
  qw(emerg alert crit err warning notice info debug);

sub print_syslog_message($message) {
    if ( $message =~ SYSLOG_REGEX ) {
        my $f = POSIX::floor( $1 / 8 );
        my $s = $1 - $f * 8;
        say(    (SYSLOG_FACILITIES)[$f] . "."
              . (SYSLOG_SEVERITIES)[$s] . " "
              . $2 );
    }
    else {
        say $message;    # dump message as is
    }
}

sub setup_syslog_server() {
    socket my $server, PF_UNIX, SOCK_DGRAM, 0 or die "socket: $!";
    unlink(SYSLOG_SERVER_SOCKET);
    bind $server, sockaddr_un(SYSLOG_SERVER_SOCKET) or die "bind: $!";
    $server;
}

sub collect_syslog_messages( $socket, $timeout = EVENT_LOOP_SLEEP ) {
    my $buf = "";

    # Wait $timeout sec for the $socket to be readable
    my $rin = "";
    vec( $rin, fileno($socket), 1 ) = 1;
    my $nfound = select( my $rout = $rin, undef, undef, $timeout );
    die_unless_eintr "select: $!" if $nfound < 0;
    if ($rout) {
        my $rhost = recv $socket, $buf, SYSLOG_MSG_MAXLEN, 0;
        die_unless_eintr "recv: $!" unless defined $rhost;
        print_syslog_message $buf;
    }
}

## Templates
sub collect_templates($dir) {
    my @templates = ();
    opendir( my $dh, $dir ) or die "opendir ${dir}: $!";
    while ( my $dentry = readdir($dh) ) {
        next if $dentry =~ /^\.\.?$/;    # skip '.' and '..'
        my $dname = File::Spec->join( $dir, $dentry );
        push @templates, collect_templates($dname) if ( -d $dname );
        push @templates, $dname                    if ( -f $dname );
    }
    closedir($dh);
    @templates;
}

sub render_templates() {
    my $dir       = File::Spec->join( PINITO_DIR, "templates" );
    my @templates = collect_templates($dir);
    foreach my $tfile (@templates) {
        my $dstfile =
          File::Spec->join( "/", File::Spec->abs2rel( $tfile, $dir ) );

        my $tt = Text::Template->new(
            TYPE       => 'FILE',
            SOURCE     => $tfile,
            PREPEND    => 'use v5.36;',
            DELIMITERS => [ '<%', '%>' ],
        );

        open my $dfh, '>', $dstfile or die "open ${dstfile}: $!";
        $tt->fill_in(
            PACKAGE => 'P',
            HASH    => {
                ENV => $ENV,
            },
            OUTPUT => \*$dfh,
        );
        close $dfh;
    }
}

## Services
# Run a program in a forked process
sub run(@args) {
    my $pid = fork;
    die "cannot fork" unless defined $pid;

    if ($pid) {

        # Parent => return child's pid
        $children{$pid} = 1;
        return $pid;
    }

    # Child never returns
    exec { $args[0] } @args;
    exit 1;
}

### MAIN

chdir "/";
setup_signal_handling();
render_templates();

my $syslog_server = setup_syslog_server if (SYSLOG_SERVER_ENABLED);

my $service_file = $ARGV[0] || File::Spec->join( PINITO_DIR, "services" );
my $rc           = do $service_file;
die "cannot parse service definitions" unless defined $rc;

while ($keep_going) {
    if (SYSLOG_SERVER_ENABLED) {
        collect_syslog_messages($syslog_server);
    }
    else {
        sleep EVENT_LOOP_SLEEP;
    }
}

exit 0;

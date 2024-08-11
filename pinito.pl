#!/usr/bin/env perl
# vim: ts=4 sw=4 et ci

use v5.36;
use POSIX ":sys_wait_h";
use File::Spec;
use Socket;

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
my %children        = ();
my %forward_signals = ();
my %quit_signals    = (
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

## Syslog server
# Arrays to decode syslog facilities/severities
use constant SYSLOG_FACILITIES =>
  qw(kern user mail daemon auth syslog lpr news uucp cron authpriv ftp ntp security console
  solaris-cron local0 local1 local2 local3 local4 local5 local6 local7);
use constant SYSLOG_SEVERITIES =>
  qw(emerg alert crit err warning notice info debug);

sub notice($msg) {
    say $msg;
}

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
    chmod 0666, SYSLOG_SERVER_SOCKET || die "chmod: $!";
    $server;
}

sub collect_syslog_messages( $socket, $timeout = EVENT_LOOP_SLEEP ) {
    my $buf = "";
    my $rin = "";
    vec( $rin, fileno($socket), 1 ) = 1;

    # Wait $timeout sec for the $socket to be readable
    my $nfound = select( my $rout = $rin, undef, undef, $timeout );

    return undef if ( $nfound == 0 );    # Timeout expired
    if ( $nfound < 0 ) {
        return undef if ( $!{EINTR} );    # select() interrupted by a signal
        die "select: $!";
    }

    my $rhost = recv $socket, $buf, SYSLOG_MSG_MAXLEN, 0;
    unless ( defined $rhost ) {
        return undef if $!{EINTR};
        die "recv: $!";
    }
    print_syslog_message $buf;
    $buf;
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

# Run modes
use constant {
    ONESHOT    => 1,
    SUPERVISED => 2,
};

my @services = ();

# Add service to the list
sub service( $mode, @args ) {
    push @services, { 'pid' => 0, 'mode' => $mode, 'cmd' => [@args] };
}

# Run a program in a forked process
sub spawn_cmd($args) {
    my $pid = fork;
    die "cannot fork" unless defined $pid;

    if ($pid) {    # Parent => return child's pid
        $children{$pid} = 1;
        return $pid;
    }

    # Child never returns
    exec { $args->[0] } @$args;
    exit 1;
}

### MAIN

chdir "/";
setup_signal_handling();
render_templates();

# If anything is given in the command line arguments, then execute it instead
if (scalar @ARGV > 0) {
    exec { $ARGV[0] } @ARGV;
    exit 1;
}

my $syslog_server = setup_syslog_server if (SYSLOG_SERVER_ENABLED);

my $service_file = File::Spec->join( PINITO_DIR, "services" );
my $rc           = do $service_file;
die "cannot parse service definitions" unless defined $rc;

# Start services
foreach my $svc (@services) {
    notice "Starting `" . join( ' ', @{ $svc->{'cmd'} } ) . "`...";
    my $pid = spawn_cmd( $svc->{'cmd'} );
    $svc->{'pid'} = $pid if $svc->{'mode'} == SUPERVISED;

    # Collect syslog messages produced by the service (if any)
    if (SYSLOG_SERVER_ENABLED) {
        while ( collect_syslog_messages($syslog_server) ) { }
    }
}

# Delete non-supervised services
@services = grep { $_->{'mode'} == SUPERVISED } @services;

my $idx = 0;

# Run main loop
while ($keep_going) {
    if (SYSLOG_SERVER_ENABLED) {
        while ( collect_syslog_messages($syslog_server) ) { }
    }
    else {
        sleep EVENT_LOOP_SLEEP;
    }

    # Check one supervised process per loop iteration
    # Died process pid is deleted from %children hash by SIGCHLD handler
    my $svc = $services[$idx];
    unless ( exists $children{ $svc->{'pid'} } ) {
        notice "Restarting `" . join( ' ', @{ $svc->{'cmd'} } ) . "`...";
        $svc->{'pid'} = spawn_cmd( $svc->{'cmd'} );
    }
    $idx = 0 if ++$idx >= scalar @services;
}

exit 0;

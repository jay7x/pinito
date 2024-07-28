# Minimal init system for containers

This is unique init system to use with Linux (and maybe *BSD) containers, written in Perl. Why in Perl? Because Debian-based containers has the `perl-base` package bundled.

## Built-in features

1. Template support with bundled Text::Template module. See [Text::Template](https://metacpan.org/pod/Text::Template) documentation.
1. Built-in syslog server enabled by default. It listens on `/dev/log` and forwards messages to stdout.
1. Ability to start multiple child processes (see `pinito/services` file for details).
1. Common signals are forwarded to the processes spawned.

## TODO

- GHA to release a tarball
- Ability to watch and restart the services spawned
- Ability to filter signals forwarding

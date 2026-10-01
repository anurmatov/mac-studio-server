#!/bin/sh
# hold-mut-ex.sh — hold LOCK_EX on the mutation file until killed (MB28), so a
# mss_mut runner blocks before its LOCK_SH. Prints "held <pid>".
exec /usr/bin/perl -e 'use Fcntl qw(:DEFAULT :flock); sysopen(my $m, $ARGV[0], O_RDWR | O_CREAT, 0600) or die "$!\n"; flock($m, LOCK_EX) or die "$!\n"; $| = 1; print "held $$\n"; sleep 1 while 1;' \
    "${MSS_MUT_FILE:-/var/run/com.mac-studio-server.mut}"

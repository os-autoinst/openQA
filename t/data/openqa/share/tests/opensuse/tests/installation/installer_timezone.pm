#!/usr/bin/perl -w
use strict;
use base "y2logsstep";
use testapi;

sub run() {
    assert_screen "inst-timezone", 125 || die 'no timezone';
    send_key $cmd{"next"};
}

1;
# vim: set sw=4 et:

#!/usr/bin/env perl

# Summary: Verify timezone settings page
# Maintainer: Allison Average <allison@example.com>

use Mojo::Base 'y2logsstep';
use testapi;

sub run () {
    assert_screen 'inst-timezone', 125 || die 'no timezone';
    send_key $cmd{next};
}

1;

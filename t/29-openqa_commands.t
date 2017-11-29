#!/usr/bin/env perl -w
# Copyright (C) 2017 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;
# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;
use FindBin;
use lib ("$FindBin::Bin/lib", "../lib", "lib");
use Test::More;
use OpenQA;
use Test::Output 'stderr_like';

subtest _run => sub {
    stderr_like sub {
        OpenQA::_run("fake", sub { Devel::Cover::report() if Devel::Cover->can('report') });
    }, qr/fake started with pid/;
};

subtest _stopAll => sub {
    OpenQA::_run("fake", sub { $| = 1; print "Boo" while sleep 1; });

    stderr_like sub {
        OpenQA::_stopAll();
    }, qr/stopping fake with pid /;
};

subtest run => sub {
    $ARGV[0] = "daemon";
    stderr_like sub { OpenQA::run(); }, qr/webapi started/;

    stderr_like sub {
        OpenQA::run();
    }, qr/stopping webapi with pid/;
    OpenQA::_stopAll();

    $ARGV[0] = "";
    my $touched;
    use Mojo::Util 'monkey_patch';
    monkey_patch "OpenQA::WebAPI", run => sub { $touched++ };
    OpenQA::run();
    is $touched, 1;
};

done_testing;
